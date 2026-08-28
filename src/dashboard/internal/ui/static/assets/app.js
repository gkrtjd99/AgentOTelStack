(() => {
  'use strict';
  const state = { service: '', lookback: '15m', limit: 50, traceId: '' };
  const requests = window.dashboardRequestState ? window.dashboardRequestState() : null;
  const fallbackRequests = (() => {
    const active = new Map();
    return {
      begin(view) {
        const previous = active.get(view);
        if (previous) previous.controller.abort();
        const request = { controller: new AbortController() };
        active.set(view, request);
        return request;
      },
      current(view, request, activeView) { return (activeView === undefined || activeView === view) && active.get(view) === request && !request.controller.signal.aborted; },
      validClientToken: (value) => typeof value === 'string' && /^[0-9a-f]{64}$/.test(value),
      bootstrapToken: (hash, scrub) => {
        if (!hash.startsWith('#token=')) return { attempted: false, token: '' };
        const token = hash.slice('#token='.length);
        scrub();
        return { attempted: true, token: /^[0-9a-f]{64}$/.test(token) ? token : '' };
      },
    };
  })();
  const requestState = requests || fallbackRequests;
  const $ = (id) => document.getElementById(id);
  const text = (value, fallback = '—') => {
    const node = document.createTextNode(value === undefined || value === null || value === '' ? fallback : String(value));
    return node;
  };
  const validTrace = (value) => /^[0-9a-f]{32}$/.test(value);
  const currentView = () => {
    const name = location.hash.slice(1);
    return ['overview', 'services', 'errors', 'trace'].includes(name) ? name : 'overview';
  };
  const setState = (kind, label) => {
    const node = $('query-state');
    node.className = `query-state status-${kind}`;
    node.replaceChildren(Object.assign(document.createElement('span'), { className: 'status-icon', textContent: kind === 'ok' ? '✓' : kind === 'error' ? '!' : '•' }), text(label));
  };
  const bootstrap = requestState.bootstrapToken(location.hash, () => history.replaceState(null, '', '#overview'));
  const clientToken = bootstrap.token;
  const authReady = requestState.validClientToken(clientToken);
  const setFetched = (id, value) => { $(id).textContent = value ? `Fetched at ${value} (not telemetry freshness)` : 'Not fetched'; };
  const api = async (path, options = {}) => {
    if (!authReady || !path.startsWith('/api/')) throw new Error('Dashboard access token required');
    const request = { credentials: 'omit', cache: 'no-store', redirect: 'error', ...options };
    const headers = new Headers(request.headers || {});
    headers.set('Authorization', `Dashboard ${clientToken}`);
    request.headers = headers;
    const response = await fetch(path, request);
    let payload = null;
    try { payload = await response.json(); } catch (_) { payload = null; }
    if (!response.ok) throw new Error(payload && payload.error ? payload.error : `Request failed (${response.status})`);
    return payload;
  };
  const clear = (id) => { $(id).replaceChildren(); };
  const banner = (view, id) => {
    const target = $(id); clear(id);
    const notices = [];
    if (view && view.partial) notices.push('Some backend signals are unavailable. This view is partial.');
    if (view && view.truncated) notices.push('The source or dashboard response was truncated. Interpret the sample cautiously.');
    if (view && view.content_trust !== 'untrusted_telemetry') notices.push(`Content trust is ${view.content_trust || 'unknown'}; telemetry is not verified input.`);
    if (!notices.length) return;
    notices.forEach((notice) => { const box = document.createElement('div'); box.className = 'banner'; box.append(text('!'), Object.assign(document.createElement('span'), { textContent: notice })); target.append(box); });
  };
  const statusClass = (status) => status === 'ok' ? 'ok' : ['no_matching', 'no_matching_data', 'trace_not_stored', 'signal_not_observed'].includes(status) ? 'warning' : 'error';
  const renderBackends = (view, id) => {
    const target = $(id); clear(id);
    const backends = Array.isArray(view && view.backends) ? view.backends : [];
    if (!backends.length) { target.append(empty('No backend status reported.')); return; }
    backends.forEach((backend) => {
      const card = document.createElement('div'); card.className = `status-card ${statusClass(backend.status)}`;
      const dot = Object.assign(document.createElement('span'), { className: 'status-dot', ariaHidden: 'true' });
      const copy = document.createElement('div'); const title = document.createElement('h3'); title.append(text(backend.name, 'Unknown backend'));
      const detail = document.createElement('p'); detail.append(text(`${backend.status || 'unsupported'}${backend.error ? ` — ${backend.error}` : ''}`));
      copy.append(title, detail); card.append(dot, copy); target.append(card);
    });
  };
  const empty = (message) => Object.assign(document.createElement('div'), { className: 'empty-state', textContent: message });
  const tableMessage = (id, colspan, message) => {
    const target = $(id); clear(id);
    const row = document.createElement('tr');
    const cell = document.createElement('td'); cell.colSpan = colspan; cell.className = 'empty-state'; cell.append(text(message));
    row.append(cell); target.append(row);
  };
  const renderLogs = (logs, id, allowTrace = false) => {
    const target = $(id); clear(id);
    if (!Array.isArray(logs) || !logs.length) { target.append(empty('No known log records in this response.')); return; }
    const list = document.createElement('div'); list.className = 'signal-list';
    logs.slice(0, 50).forEach((record) => {
      const row = document.createElement('div'); row.className = 'signal-row';
      const meta = document.createElement('div'); meta.className = 'signal-meta';
      [record.timestamp, record.service, record.severity].filter(Boolean).forEach((value) => meta.append(text(value)));
      const message = document.createElement('p'); message.className = 'signal-message'; message.append(text(record.message));
      row.append(meta, message);
      if (allowTrace && validTrace(record.trace_id)) { const button = document.createElement('button'); button.className = 'trace-link'; button.type = 'button'; button.textContent = `Open trace ${record.trace_id}`; button.addEventListener('click', () => openTrace(record.trace_id)); row.append(button); }
      list.append(row);
    });
    target.append(list);
  };
  const renderMetrics = (metrics, id) => {
    const target = $(id); clear(id);
    if (!Array.isArray(metrics) || !metrics.length) { target.append(empty('No known metric snapshot in this response.')); return; }
    const list = document.createElement('div'); list.className = 'signal-list';
    metrics.slice(0, 50).forEach((metric) => { const row = document.createElement('div'); row.className = 'signal-row'; const meta = document.createElement('div'); meta.className = 'signal-meta'; meta.append(text(metric.service, 'Unknown service')); const value = document.createElement('p'); value.className = 'signal-message'; value.append(text(metric.value, 'Value unavailable')); row.append(meta, value); list.append(row); });
    target.append(list);
  };
  const renderServices = (view) => {
    banner(view, 'services-banners'); setFetched('services-fetched', view && view.fetched_at); const target = $('services-list'); clear('services-list');
    const services = view && view.data && view.data.supported && Array.isArray(view.data.services) ? view.data.services : [];
    if (!services.length) { target.append(empty(view && view.data && view.data.supported ? 'No services observed in the selected scope.' : 'Service shape is unavailable.')); return; }
    services.forEach((service) => { const row = document.createElement('div'); row.className = 'service-item'; const name = document.createElement('span'); name.className = 'service-name'; name.append(text(service)); const select = document.createElement('button'); select.className = 'trace-link'; select.type = 'button'; select.textContent = 'Use service'; select.addEventListener('click', () => { $('service-select').value = service; state.service = service; if (location.hash === '#overview' || location.hash === '') loadOverview(); else location.hash = '#overview'; }); row.append(name, select); target.append(row); });
  };
  const renderErrors = (view) => {
    banner(view, 'errors-banners'); renderBackends(view, 'errors-backends'); setFetched('errors-fetched', view && view.fetched_at); const body = $('errors-table'); clear('errors-table');
    const errors = view && view.data && Array.isArray(view.data.errors) ? view.data.errors : [];
    if (!errors.length) { tableMessage('errors-table', 4, view && view.data && view.data.supported ? 'No recent errors observed.' : 'Error shape is unavailable.'); return; }
    errors.slice(0, 100).forEach((error) => { const row = document.createElement('tr'); [error.timestamp, error.service, error.message || error.operation].forEach((value) => { const cell = document.createElement('td'); cell.append(text(value)); row.append(cell); }); const trace = document.createElement('td'); if (validTrace(error.trace_id)) { const button = document.createElement('button'); button.className = 'trace-link'; button.type = 'button'; button.textContent = error.trace_id; button.addEventListener('click', () => openTrace(error.trace_id)); trace.append(button); } else trace.append(text('Not available')); row.append(trace); body.append(row); });
  };
  const renderCorrelation = (view) => {
    banner(view, 'trace-banners'); renderBackends(view, 'trace-backends'); setFetched('trace-fetched', view && view.fetched_at); const body = $('trace-table'); clear('trace-table'); const spans = view && view.data && Array.isArray(view.data.spans) ? view.data.spans : [];
    if (!spans.length) { const row = document.createElement('tr'); const cell = document.createElement('td'); cell.colSpan = 5; cell.className = 'empty-state'; cell.append(text(view && view.data && view.data.supported ? 'No known spans returned.' : 'Trace shape is unavailable.')); row.append(cell); body.append(row); } else spans.forEach((span) => { const row = document.createElement('tr'); [span.service, span.operation, span.start_time, span.duration, span.status].forEach((value) => { const cell = document.createElement('td'); cell.append(text(value)); row.append(cell); }); body.append(row); });
    renderLogs(view && view.data && view.data.logs, 'trace-logs'); renderMetrics(view && view.data && view.data.metrics, 'trace-metrics');
  };
  const isCurrent = (view, request, allowedViews = [view]) => allowedViews.includes(currentView()) && requestState.current(view, request);
  const loadOverview = async () => {
    const request = requestState.begin('overview');
    setState('warning', 'Loading context');
    try {
      const query = new URLSearchParams(); if (state.service) query.set('service', state.service); query.set('lookback', state.lookback); query.set('limit', String(state.limit));
      const view = await api(`/api/context?${query}`, { signal: request.controller.signal });
      if (!isCurrent('overview', request)) return;
      banner(view, 'overview-banners'); renderBackends(view, 'overview-backends'); setFetched('overview-fetched', view.fetched_at); renderMetrics(view.data && view.data.metrics, 'overview-metrics'); renderLogs(view.data && view.data.logs, 'overview-logs', true); setState(view.partial ? 'warning' : 'ok', view.partial ? 'Context partial' : 'Context ready');
    } catch (error) {
      if (!isCurrent('overview', request) || error.name === 'AbortError') return;
      setState('error', error.message); $('overview-banners').replaceChildren(Object.assign(document.createElement('div'), { className: 'banner', textContent: `Unable to load context: ${error.message}` }));
    }
  };
  const loadServices = async () => {
    const request = requestState.begin('services');
    try {
      const view = await api('/api/services', { signal: request.controller.signal });
      if (!isCurrent('services', request, ['overview', 'services'])) return;
      renderServices(view); const select = $('service-select'); const current = state.service || select.value; select.replaceChildren(new Option('All services', '')); (view.data && view.data.services || []).forEach((service) => select.append(new Option(service, service))); select.value = current;
      if (currentView() === 'services') setState('ok', 'Services ready');
    } catch (error) {
      if (!isCurrent('services', request, ['overview', 'services']) || error.name === 'AbortError') return;
      $('services-list').replaceChildren(empty(`Unable to load services: ${error.message}`));
      if (currentView() === 'services') setState('error', error.message);
    }
  };
  const loadErrors = async () => {
    const request = requestState.begin('errors');
    try {
      const query = new URLSearchParams(); if (state.service) query.set('service', state.service); query.set('lookback', state.lookback); query.set('limit', String(state.limit));
      const view = await api(`/api/errors?${query}`, { signal: request.controller.signal });
      if (!isCurrent('errors', request)) return;
      renderErrors(view); setState(view.partial ? 'warning' : 'ok', view.partial ? 'Errors partial' : 'Errors ready');
    } catch (error) {
      if (!isCurrent('errors', request) || error.name === 'AbortError') return;
      tableMessage('errors-table', 4, `Unable to load errors: ${error.message}`);
      setState('error', error.message);
    }
  };
  const loadTrace = async () => {
    if (!validTrace(state.traceId)) return;
    const request = requestState.begin('trace');
    setState('warning', 'Loading trace');
    try {
      const view = await api('/api/correlate', { method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify({ trace_id: state.traceId, limit: state.limit }), signal: request.controller.signal });
      if (!isCurrent('trace', request)) return;
      renderCorrelation(view); setState(view.partial ? 'warning' : 'ok', view.partial ? 'Trace partial' : 'Trace ready');
    } catch (error) {
      if (!isCurrent('trace', request) || error.name === 'AbortError') return;
      setState('error', error.message); $('trace-banners').replaceChildren(Object.assign(document.createElement('div'), { className: 'banner', textContent: `Unable to load trace: ${error.message}` }));
    }
  };
  const openTrace = (traceId) => {
    if (!validTrace(traceId)) return;
    state.traceId = traceId; $('trace-input').value = traceId; location.hash = '#trace'; show('trace'); loadTrace();
  };
  const show = (name) => {
    document.querySelectorAll('[data-panel]').forEach((panel) => panel.classList.toggle('hidden', panel.dataset.panel !== name)); document.querySelectorAll('nav a[data-view]').forEach((link) => link.setAttribute('aria-current', link.dataset.view === name ? 'page' : 'false'));
    if (name === 'overview') { loadOverview(); loadServices(); }
    if (name === 'services') loadServices();
    if (name === 'errors') loadErrors();
    // Trace loading is explicit: opening a trace or submitting the form is the only trigger.
  };
  const route = () => { if (!authReady) return; const name = currentView(); show(name); };
  const reloadForScope = () => {
    const view = currentView();
    if (view === 'overview') loadOverview();
    else if (view === 'errors') loadErrors();
    else if (view === 'trace') setState('warning', 'Trace view uses its explicit trace ID; scope applies to overview and errors');
    else setState('ok', 'Service list does not use service or lookback scope');
  };
  $('service-select').addEventListener('change', (event) => { state.service = event.target.value; reloadForScope(); });
  $('lookback-select').addEventListener('change', (event) => { state.lookback = event.target.value; reloadForScope(); });
  $('refresh').addEventListener('click', () => {
    const view = currentView();
    if (view === 'overview') loadOverview(); else if (view === 'services') loadServices(); else if (view === 'errors') loadErrors(); else if (state.traceId) loadTrace(); else setState('warning', 'Enter a trace ID before refreshing trace detail');
  });
  $('trace-form').addEventListener('submit', (event) => { event.preventDefault(); openTrace($('trace-input').value.trim()); });
  $('theme-toggle').addEventListener('click', () => { const dark = document.documentElement.dataset.theme === 'dark'; document.documentElement.dataset.theme = dark ? 'light' : 'dark'; $('theme-toggle').textContent = dark ? 'Use dark mode' : 'Use light mode'; $('theme-toggle').setAttribute('aria-pressed', String(!dark)); });
  window.addEventListener('hashchange', route);
  if (!authReady) {
    setState('error', 'Dashboard access token required');
    $('overview-banners').replaceChildren(Object.assign(document.createElement('div'), { className: 'banner', textContent: 'Open the one-time bootstrap URL printed by the dashboard startup command.' }));
  } else {
    route();
  }
})();
