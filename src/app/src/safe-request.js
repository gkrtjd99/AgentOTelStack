// Return only a request pathname for logs. URL parsing is anchored to a dummy
// origin because incoming Node request URLs are usually relative and may
// contain attacker-controlled query strings.
const pathnameOnly = (url) => {
  if (typeof url !== "string" || url.length === 0) return "/";
  try {
    return new URL(url, "http://agentotel.invalid").pathname || "/";
  } catch {
    return url.split(/[?#]/, 1)[0] || "/";
  }
};

const safeReq = (req) => ({ method: req.method, url: pathnameOnly(req.url) });

module.exports = { pathnameOnly, safeReq };
