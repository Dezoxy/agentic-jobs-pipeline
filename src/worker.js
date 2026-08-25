// Tracker sync API. One KV key, one user, behind Cloudflare Access.
//
// The Worker performs no authentication itself — same stance as the static
// half (README "Access control"): every request that reaches it already
// passed the Access policy on the hostname. That policy is what keeps both
// the job list AND this tracker private; if it is ever removed, this
// endpoint becomes publicly readable and writable immediately.
//
// Asset requests are served by the platform before the script runs
// (run_worker_first is off), so this code only sees non-asset paths.

// Must match TRACKER_STATUSES in public/app.js.
const STATUSES = new Set(["saved", "applied", "interview", "offer", "rejected", "ignored"]);
const KEY = "tracker";
const MAX_BYTES = 512 * 1024; // ~5000 entries is <200 KB; anything bigger is garbage

// Same shape check as public/app.js's sanitizeTrackerImport, server-side:
// a malformed PUT must not be able to wedge every device's next sync.
function sanitize(raw) {
  if (typeof raw !== "object" || raw === null || Array.isArray(raw)) return null;
  const clean = {};
  for (const [id, v] of Object.entries(raw)) {
    if (typeof id !== "string" || id.length > 200) return null;
    if (typeof v !== "object" || v === null || Array.isArray(v)) return null;
    if (!STATUSES.has(v.st) || typeof v.at !== "string" || v.at.length > 40) return null;
    clean[id] = { st: v.st, at: v.at };
  }
  return clean;
}

const json = (body, status = 200) => new Response(JSON.stringify(body), {
  status,
  headers: { "Content-Type": "application/json", "Cache-Control": "no-store" },
});

export default {
  async fetch(request, env) {
    const url = new URL(request.url);

    if (url.pathname === "/api/tracker") {
      if (request.method === "GET") {
        const stored = await env.TRACKER.get(KEY);
        return new Response(stored ?? "{}", {
          headers: { "Content-Type": "application/json", "Cache-Control": "no-store" },
        });
      }
      if (request.method === "PUT") {
        const text = await request.text();
        if (text.length > MAX_BYTES) return json({ error: "too large" }, 413);
        let raw;
        try { raw = JSON.parse(text); } catch { return json({ error: "invalid JSON" }, 400); }
        const clean = sanitize(raw);
        if (!clean) return json({ error: "invalid tracker shape" }, 400);
        await env.TRACKER.put(KEY, JSON.stringify(clean));
        return json({ ok: true, entries: Object.keys(clean).length });
      }
      return json({ error: "method not allowed" }, 405);
    }

    // Anything else that reached the script is a non-asset path: let the
    // assets binding produce the same 404-page behavior as before.
    return env.ASSETS.fetch(request);
  },
};
