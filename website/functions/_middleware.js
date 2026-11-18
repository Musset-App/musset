// On the home page, a visitor lands in their language: the one they chose in the footer (a cookie), else the first
// of their browser's languages the site has. English stays at /; the others live at /fr/, /de/…
const LANGS = ["en", "fr", "de", "es", "it", "pt"];

function fromBrowser(header) {
  const wanted = header.split(",").map((part, i) => {
    const [tag, ...params] = part.trim().split(";");
    const q = params.map((p) => p.trim()).find((p) => p.startsWith("q="));
    return { lang: tag.toLowerCase().split("-")[0], q: q ? parseFloat(q.slice(2)) || 0 : 1, i };
  }).filter((w) => w.lang && w.q > 0).sort((a, b) => b.q - a.q || a.i - b.i);
  return (wanted.find((w) => LANGS.includes(w.lang)) || { lang: "en" }).lang;
}

export async function onRequest(context) {
  const url = new URL(context.request.url);
  if (url.pathname !== "/") return context.next();
  const cookie = (context.request.headers.get("Cookie") || "").match(/(?:^|;\s*)lang=([a-z]{2})/);
  const lang = cookie && LANGS.includes(cookie[1]) ? cookie[1] : fromBrowser(context.request.headers.get("Accept-Language") || "");
  if (lang !== "en") {
    return new Response(null, { status: 302, headers: { Location: `/${lang}/`, Vary: "Accept-Language, Cookie", "Cache-Control": "private, no-store" } });
  }
  const response = await context.next();
  const page = new Response(response.body, response);
  page.headers.set("Vary", "Accept-Language, Cookie");
  return page;
}
