// Adds one to a counter in the D1 database STATS (stats/schema.sql). Counts only: no address, no identifier.
// Never in the way of the answer: it runs after it, and a failure is dropped.
const ROBOT = /bot|crawl|spider|slurp|preview|monitor/i;

// The app's updater names itself "Musset/0.4.0 Sparkle/2.9.6".
export function sparkle(request) {
  const m = (request.headers.get("User-Agent") || "").match(/^Musset\/(\d+\.\d+\.\d+)\b.*\bSparkle\//);
  return m ? m[1] : null;
}

export function count({ env, request, waitUntil }, kind, version) {
  if (!env.STATS || ROBOT.test(request.headers.get("User-Agent") || "")) return;
  const day = new Date().toISOString().slice(0, 10);
  const country = (request.cf && request.cf.country) || "";
  waitUntil(env.STATS.prepare(
    "INSERT INTO counts (day, kind, version, country, n) VALUES (?, ?, ?, ?, 1) " +
    "ON CONFLICT (day, kind, version, country) DO UPDATE SET n = n + 1"
  ).bind(day, kind, version, country).run().catch(() => {}));
}
