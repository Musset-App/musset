#!/usr/bin/env python3
"""Builds musset.app: one page per language from template.html and strings/<lang>.json, into dist/.

    python3 website/build.py            then    cd website && npx wrangler pages deploy dist --project-name musset

English is at /, the others at /fr/, /de/… On /, functions/_middleware.js sends a visitor to their browser's
language (or the one they chose in the footer, kept in a cookie). A string missing from a language falls back to
English.
"""
import hashlib
import html
import json
import re
import shutil
from pathlib import Path

HERE = Path(__file__).resolve().parent
SITE = "https://musset.app"
# Code, name in its own language, html lang.
LANGS = [("en", "English", "en"), ("fr", "Français", "fr"), ("de", "Deutsch", "de"),
         ("es", "Español", "es"), ("it", "Italiano", "it"), ("pt", "Português", "pt-BR")]


# The design's pictures, by what they show; each language has its own, made by scripts/site-shots.sh in
# assets/<lang>/. The second manuscript is another country's: the German Normseite beside the US manuscript, the US
# manuscript beside every other language's own.
IMAGES = {
    "fa0ec9ca1ab5e94ec0b2dd6c067bef50": "editor", "2dae496974c1bd571041c8baf6ecf8ca": "notes",
    "48d30d6bd98bb342be551429f903177c": "chat", "7b472c688ee4aff5b79b9f13e0a512e0": "command-bar",
    "c27d45c67803f07bb9a80ddb824b09e9": "reading", "53fc98b7cabce5572252462d6b8fa35d": "book-left",
    "dc6c2df539b2673af252f7adde8d0cda": "book-right", "3da782a0371060354d2c40b05694b0aa": "manuscript",
    "8d33690692a4c385b7c2b1be8e4c692a": "versions", "19358ff6a6d98fd02663a0a94c922966": "corrections",
}
FOREIGN_MANUSCRIPT = "36f75b02213e4462dae38375a79f65b1"


def images(page, code):
    for h, name in IMAGES.items():
        page = page.replace(f"/assets/{h}.jpg", f"/assets/{code}/{name}.jpg")
    page = page.replace(f"/assets/{FOREIGN_MANUSCRIPT}.jpg", f"/assets/{'de' if code == 'en' else 'en'}/manuscript.jpg")
    page = page.replace("/assets/LANG/", f"/assets/{code}/")
    # Pictures are cached for a year: a picture that changed gets a new address.
    def stamped(m):
        f = HERE / m.group(0).lstrip("/")
        return m.group(0) + (f"?v={hashlib.sha1(f.read_bytes()).hexdigest()[:8]}" if f.exists() else "")
    return re.sub(r"/assets/[a-z]{2}/[\w-]+\.jpg", stamped, page)


def path(code):
    return "/" if code == "en" else f"/{code}/"


def switcher(current, label):
    links = []
    for code, name, tag in LANGS:
        attrs = ' aria-current="page" style="color: #1A1A18; font-weight: 600; text-decoration: none"' if code == current \
            else ' style="color: #6B665C; text-decoration: none"'
        links.append(f'<a href="{path(code)}" hreflang="{tag}" lang="{tag}" data-lang="{code}"{attrs}>{name}</a>')
    return (f'<nav class="wrap" aria-label="{html.escape(label)}" style="display: flex; flex-wrap: wrap; gap: 18px; '
            f'padding-top: 20px; font-size: 13px">{"".join(links)}</nav>\n'
            # The choice outlives the visit: / then opens in it, whatever the browser says.
            '<script>document.querySelectorAll("a[data-lang]").forEach(function(a){a.addEventListener("click",function(){'
            'document.cookie="lang="+a.dataset.lang+";path=/;max-age=31536000;samesite=lax"})})</script>')


def compare_pages(dist):
    """The comparison pages, in English: /compare/ and /compare/<slug>/, from compare.html and compare/pages.json.

    The texts in pages.json are plain text; they are escaped here. Returns the pages as (path, link text)."""
    data = json.loads((HERE / "compare/pages.json").read_text(encoding="utf-8"))
    template = (HERE / "compare.html").read_text(encoding="utf-8")
    e = lambda t: html.escape(t, quote=False)
    paras = lambda ps: "".join(f"<p>{e(t)}</p>" for t in ps)
    items = lambda xs: "<ul>" + "".join(f"<li><span>{e(x)}</span></li>" for x in xs) + "</ul>"
    pages = [(f"/compare/{p['slug']}/", f"Musset vs {p['name']}") for p in data["pages"]]

    def write(where, title, description, body, current=None):
        links = " · ".join(f'<a href="{href}">{e(text)}</a>' for href, text in pages if href != current)
        page = template
        for key, value in {"title": html.escape(title), "description": html.escape(description, quote=True),
                           "canonical": SITE + where, "body": body, "footer_links": links}.items():
            page = page.replace("{{" + key + "}}", value)
        left = re.search(r"\{\{\w+\}\}", page)
        if left:
            raise SystemExit(f"compare{where}: no value for {left.group(0)}")
        out = dist / where.strip("/") / "index.html"
        out.parent.mkdir(parents=True, exist_ok=True)
        out.write_text(images(page, "en"), encoding="utf-8")

    for p in data["pages"]:
        name, where = p["name"], f"/compare/{p['slug']}/"
        rows = "".join(f'<tr><th scope="row">{e(r["label"])}</th><td class="us">{e(r["musset"])}</td>'
                       f'<td>{e(p["values"][r["key"]])}</td></tr>' for r in data["rows"])
        sections = "".join(f'<section><div class="wrap narrow"><h2>{e(s["h"])}</h2>{paras(s["p"])}</div></section>'
                           for s in p["sections"])
        sources = " · ".join(f'<a href="{html.escape(u, quote=True)}" rel="nofollow noopener">{e(t)}</a>' for t, u in p["sources"])
        body = f"""<div class="wrap hero">
<p class="eyebrow">{e(p["eyebrow"])}</p>
<h1>{e(p["h1"])}</h1>
<p class="lede">{e(p["lede"])}</p>
<div><a class="cta" href="/download">Download Musset — free</a></div>
</div>
<div class="wrap"><img class="shot" src="/assets/en/{p["picture"]}.jpg" alt="{html.escape(p["picture_alt"], quote=True)}" width="1920" height="1200"></div>
<section><div class="wrap narrow"><h2>{e(p["intro_h"])}</h2>{paras(p["intro"])}</div></section>
<section><div class="wrap">
<h2>Musset and {e(name)}, side by side</h2>
<div class="scroll"><table>
<thead><tr><th scope="col"></th><th scope="col">Musset</th><th scope="col">{e(name)}</th></tr></thead>
<tbody>{rows}</tbody>
</table></div>
<p class="note" style="margin-top: 16px">{e(name)}’s details were read on its maker’s own site on {e(p.get("checked", data["checked"]))}: {sources}. Tell us if something is out of date: hello@musset.app.</p>
</div></section>
<section><div class="wrap">
<h2>Which one is for you</h2>
<div class="pick">
<div><h3>Choose Musset if</h3>{items(p["musset_if"])}</div>
<div class="other"><h3>Stay with {e(name)} if</h3>{items(p["other_if"])}</div>
</div>
</div></section>
{sections}"""
        write(where, p["title"], p["description"], body, current=where)

    cards = "".join(f'<div><h3><a href="/compare/{p["slug"]}/">Musset vs {e(p["name"])}</a></h3><p>{e(p["card"])}</p></div>'
                    for p in data["pages"])
    body = f"""<div class="wrap hero">
<p class="eyebrow">Compare</p>
<h1>{e(data["index"]["h1"])}</h1>
<p class="lede">{e(data["index"]["lede"])}</p>
</div>
<section><div class="wrap"><div class="pick" style="grid-template-columns: repeat(auto-fit, minmax(260px, 1fr))">{cards}</div></div></section>"""
    write("/compare/", data["index"]["title"], data["index"]["description"], body)
    return [("/compare/", "Compare")] + pages


def main():
    template = (HERE / "template.html").read_text(encoding="utf-8")
    english = json.loads((HERE / "strings/en.json").read_text(encoding="utf-8"))
    dist = HERE / "dist"
    shutil.rmtree(dist, ignore_errors=True)
    # Only what the pages use: the pictures of each language, and the icon.
    shutil.copytree(HERE / "assets", dist / "assets", ignore=lambda d, names: [n for n in names if re.fullmatch(r"[0-9a-f]{32}\.jpg", n)])
    alternates = "\n".join([f'<link rel="alternate" hreflang="{tag}" href="{SITE}{path(code)}">' for code, _, tag in LANGS]
                           + [f'<link rel="alternate" hreflang="x-default" href="{SITE}/">'])
    for code, _, tag in LANGS:
        file = HERE / f"strings/{code}.json"
        strings = {**english, **(json.loads(file.read_text(encoding="utf-8")) if file.exists() else {})}
        values = {**strings, "lang": tag, "alternates": alternates + f'\n<link rel="canonical" href="{SITE}{path(code)}">',
                  "switcher": switcher(code, strings.get("languages", "Language")),
                  # The comparison pages are in English only, so only the English page links to them.
                  "compare": '<p class="wrap" style="margin: 20px auto 0; font-size: 13px"><a href="/compare/" style="color: #6B665C">Musset compared with Scrivener, Ulysses, iA Writer and Manuskript</a></p>' if code == "en" else ""}

        def fill(m, quoted):
            v = values.get(m.group(1))
            if v is None:
                raise SystemExit(f"{code}: no string for {m.group(1)}")
            # An attribute: the text once, entities and all (&nbsp; in an alt is a space, not "&nbsp;").
            return html.escape(html.unescape(v), quote=True) if quoted else v

        page = re.sub(r'="\{\{(\w+)\}\}"', lambda m: '="' + fill(m, True) + '"', template)
        page = re.sub(r"<title>\{\{(\w+)\}\}</title>", lambda m: "<title>" + html.escape(values[m.group(1)], quote=False) + "</title>", page)
        page = re.sub(r"\{\{(\w+)\}\}", lambda m: fill(m, False), page)
        page = images(page, code)
        out = dist / path(code).strip("/") / "index.html"
        out.parent.mkdir(parents=True, exist_ok=True)
        out.write_text(page, encoding="utf-8")
        missing = [k for k in english if k not in strings or (code != "en" and file.exists() and k not in json.loads(file.read_text(encoding="utf-8")))]
        print(f"{code}: {out.relative_to(HERE)}" + (f" ({len(missing)} strings in English)" if code != "en" and missing else ""))
    (dist / "_headers").write_text("/assets/*\n  Cache-Control: public, max-age=31536000, immutable\n/*\n  X-Content-Type-Options: nosniff\n  Referrer-Policy: strict-origin-when-cross-origin\n")
    (dist / "robots.txt").write_text(f"User-agent: *\nAllow: /\nSitemap: {SITE}/sitemap.xml\n")
    compared = compare_pages(dist)
    print("en: " + ", ".join(where for where, _ in compared))
    urls = "".join(f"<url><loc>{SITE}{where}</loc></url>" for where in [path(c) for c, _, _ in LANGS] + [w for w, _ in compared])
    (dist / "sitemap.xml").write_text(f'<?xml version="1.0" encoding="UTF-8"?><urlset xmlns="http://www.sitemaps.org/schemas/sitemap/0.9">{urls}</urlset>\n')


if __name__ == "__main__":
    main()
