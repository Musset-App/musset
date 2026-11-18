// /appcast.xml: Sparkle's update feed, from the R2 bucket. A check by the app is counted, under the version that asks.
import { count, sparkle } from "../stats/count.js";

export async function onRequest(context) {
  const { env, request } = context;
  const asking = sparkle(request);
  if (asking && request.method === "GET") count(context, "check", asking);
  const feed = await env.DOWNLOADS.get("appcast.xml");
  if (!feed) return new Response('<?xml version="1.0" encoding="utf-8"?><rss version="2.0"><channel><title>Musset</title></channel></rss>', {
    headers: { "Content-Type": "application/rss+xml; charset=utf-8" },
  });
  return new Response(feed.body, { headers: { "Content-Type": "application/rss+xml; charset=utf-8", "Cache-Control": "public, max-age=300" } });
}
