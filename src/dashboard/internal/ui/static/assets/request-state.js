((root, factory) => {
  if (typeof module === 'object' && module.exports) module.exports = factory;
  else root.dashboardRequestState = factory;
})(typeof globalThis === 'object' ? globalThis : this, () => {
  const views = new Map();
  const validClientToken = (value) => typeof value === 'string' && /^[0-9a-f]{64}$/.test(value);
  const bootstrapToken = (hash, scrub) => {
    if (!hash.startsWith('#token=')) return { attempted: false, token: '' };
    const token = hash.slice('#token='.length);
    scrub();
    return { attempted: true, token: validClientToken(token) ? token : '' };
  };
  return {
    begin(view) {
      const previous = views.get(view);
      if (previous) previous.controller.abort();
      const request = { generation: previous ? previous.generation + 1 : 1, controller: new AbortController() };
      views.set(view, request);
      return request;
    },
    current(view, request, activeView) {
      return (activeView === undefined || activeView === view) && views.get(view) === request && !request.controller.signal.aborted;
    },
    cancel(view) {
      const request = views.get(view);
      if (request) request.controller.abort();
    },
    validClientToken,
    bootstrapToken,
  };
});
