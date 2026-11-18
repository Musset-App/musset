// /download: the latest release (scripts/release.sh writes latest.json beside the DMGs).
export async function onRequest({ env, request }) {
  const latest = await env.DOWNLOADS.get("latest.json");
  if (!latest) return new Response("No release yet.", { status: 404 });
  const { file } = await latest.json();
  return Response.redirect(new URL(`/download/${file}`, request.url), 302);
}
