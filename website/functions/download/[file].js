// /download/Musset-X.Y.Z.dmg: a release (or Musset-X.Y.Z-<name>.dmg, a build for testers), from the R2 bucket. Answers byte ranges, so a stopped download resumes.
// Each download is counted once, at its first byte: as an update when the app's updater asks, else as a download.
import { count, sparkle } from "../../stats/count.js";

export async function onRequest(context) {
  const { env, params, request } = context;
  const name = String(params.file);
  // A release, or a named build beside it (Musset-0.4.0-intel-test.dmg), counted under its own name.
  if (!/^Musset-\d+\.\d+\.\d+(-[a-z0-9]+)*\.dmg$/.test(name)) return new Response("Not found.", { status: 404 });
  const head = await env.DOWNLOADS.head(name);
  if (!head) return new Response("Not found.", { status: 404 });

  const headers = new Headers();
  head.writeHttpMetadata(headers);
  headers.set("ETag", head.httpEtag);
  headers.set("Content-Disposition", `attachment; filename="${name}"`);
  headers.set("Cache-Control", "public, max-age=31536000, immutable");
  headers.set("Accept-Ranges", "bytes");

  // "bytes=a-b", "bytes=a-" or "bytes=-n"; anything else is the whole file.
  const size = head.size;
  const m = (request.headers.get("Range") || "").match(/^bytes=(\d*)-(\d*)$/);
  let range = null;
  if (m && (m[1] || m[2])) {
    let start = m[1] ? Number(m[1]) : Math.max(0, size - Number(m[2]));
    let end = m[1] && m[2] ? Math.min(Number(m[2]), size - 1) : size - 1;
    if (start >= size || start > end) {
      headers.set("Content-Range", `bytes */${size}`);
      return new Response(null, { status: 416, headers });
    }
    range = { offset: start, length: end - start + 1 };
  }

  if (request.method === "HEAD") {
    headers.set("Content-Length", String(range ? range.length : size));
    if (range) headers.set("Content-Range", `bytes ${range.offset}-${range.offset + range.length - 1}/${size}`);
    return new Response(null, { status: range ? 206 : 200, headers });
  }
  const object = await env.DOWNLOADS.get(name, range ? { range } : {});
  if (!object) return new Response("Not found.", { status: 404 });
  if (!range || range.offset === 0) count(context, sparkle(request) ? "update" : "download", name.slice(7, -4));
  if (range) {
    headers.set("Content-Range", `bytes ${range.offset}-${range.offset + range.length - 1}/${size}`);
    headers.set("Content-Length", String(range.length));
    return new Response(object.body, { status: 206, headers });
  }
  headers.set("Content-Length", String(size));
  return new Response(object.body, { headers });
}
