"""The guide: /guide/ and /guide/<slug>/, in English, from guide/*.md, guide/sections.json and guide.html.

A page is Markdown with a few lines on top:

    ---
    title: Standard manuscript format
    description: One or two sentences, for search results.
    section: publish
    order: 2
    kind: How-to
    ---

The Markdown is the small part this site needs: ## and ### headings, paragraphs, - and 1. lists (a line indented
under an item continues it), tables, ``` blocks, > notes, ![alt](picture) for a picture of assets/en, and inline
**bold**, *italic*, `code`, [links](/guide/x/) and [[⌘K]] for a key.
"""
import html
import json
import re
import subprocess
from pathlib import Path

HERE = Path(__file__).resolve().parent
SITE = "https://musset.app"
e = lambda t: html.escape(t, quote=False)


def inline(text):
    """One line of Markdown as HTML."""
    kept = []

    def keep(markup):
        kept.append(markup)
        return f"\x00{len(kept) - 1}\x00"

    text = re.sub(r"`([^`]+)`", lambda m: keep(f"<code>{e(m.group(1))}</code>"), text)
    text = re.sub(r"\[\[(.+?)\]\]", lambda m: keep(f"<kbd>{e(m.group(1))}</kbd>"), text)
    text = e(text)
    text = re.sub(r"\[([^\]]+)\]\(([^)\s]+)\)", lambda m: '<a href="%s"%s>%s</a>' % (
        m.group(2), ' rel="noopener"' if m.group(2).startswith("http") else "", m.group(1)), text)
    text = re.sub(r"\*\*(.+?)\*\*", r"<strong>\1</strong>", text)
    text = re.sub(r"(?<![\w*])\*([^*\s][^*]*?)\*(?![\w*])", r"<em>\1</em>", text)
    return re.sub(r"\x00(\d+)\x00", lambda m: kept[int(m.group(1))], text)


def slugged(text, used):
    s = re.sub(r"[^a-z0-9]+", "-", re.sub(r"[`*\[\]]", "", text).lower()).strip("-") or "section"
    n, base = 2, s
    while s in used:
        s, n = f"{base}-{n}", n + 1
    used.add(s)
    return s


def markdown(source, where):
    """The page's body, and its ## headings as (id, text) for the list on the side."""
    lines = source.split("\n")
    out, heads, used, i = [], [], set(), 0
    item = re.compile(r"^(-|\d+\.) +(.*)")
    while i < len(lines):
        line = lines[i]
        if not line.strip():
            i += 1
        elif line.startswith("```"):
            j = i + 1
            while j < len(lines) and not lines[j].startswith("```"):
                j += 1
            out.append("<pre><code>" + e("\n".join(lines[i + 1:j])) + "</code></pre>")
            i = j + 1
        elif line.startswith("#"):
            marks, text = line.split(" ", 1)
            level = len(marks)
            if level not in (2, 3):
                raise SystemExit(f"guide{where}: only ## and ### headings, not {line!r}")
            ident = slugged(text, used)
            if level == 2:
                heads.append((ident, re.sub(r"<[^>]+>", "", inline(text))))
            out.append(f'<h{level} id="{ident}">{inline(text)}</h{level}>')
            i += 1
        elif line.startswith("!["):
            m = re.fullmatch(r"!\[(.*)\]\(([\w-]+)\)", line.strip())
            if not m or not (HERE / f"assets/en/{m.group(2)}.jpg").exists():
                raise SystemExit(f"guide{where}: no picture for {line!r}")
            out.append(f'<figure><img src="/assets/en/{m.group(2)}.jpg" alt="{html.escape(m.group(1), quote=True)}" '
                       f'width="1920" height="1200" loading="lazy"></figure>')
            i += 1
        elif line.startswith("|"):
            rows = []
            while i < len(lines) and lines[i].startswith("|"):
                rows.append([c.strip() for c in lines[i].strip().strip("|").split("|")])
                i += 1
            head, body = rows[0], rows[2:]
            out.append('<div class="scroll"><table><thead><tr>' + "".join(f'<th scope="col">{inline(c)}</th>' for c in head)
                       + "</tr></thead><tbody>" + "".join(
                           "<tr>" + "".join(f"<td>{inline(c)}</td>" for c in r) + "</tr>" for r in body)
                       + "</tbody></table></div>")
        elif line.startswith(">"):
            quote = []
            while i < len(lines) and lines[i].startswith(">"):
                quote.append(lines[i][1:].strip())
                i += 1
            out.append('<aside class="note"><p>' + inline(" ".join(quote)) + "</p></aside>")
        elif item.match(line):
            tag = "ul" if line.startswith("-") else "ol"
            items = []
            while i < len(lines) and (item.match(lines[i]) or (lines[i].startswith("  ") and lines[i].strip())):
                m = item.match(lines[i])
                if m:
                    items.append(m.group(2))
                else:
                    items[-1] += " " + lines[i].strip()
                i += 1
            out.append(f"<{tag}>" + "".join(f"<li>{inline(x)}</li>" for x in items) + f"</{tag}>")
        else:
            para = []
            while i < len(lines) and lines[i].strip() and not re.match(r"(#|```|\||>|!\[|- |\d+\. )", lines[i]):
                para.append(lines[i].strip())
                i += 1
            out.append("<p>" + inline(" ".join(para)) + "</p>")
    return "\n".join(out), heads


def changed(file):
    """The day a page last changed: its last commit, else today's file."""
    try:
        day = subprocess.run(["git", "log", "-1", "--format=%cs", "--", str(file)], capture_output=True, text=True,
                             cwd=HERE).stdout.strip()
    except OSError:
        day = ""
    if not day or subprocess.run(["git", "status", "--porcelain", "--", str(file)], capture_output=True, text=True,
                                 cwd=HERE).stdout.strip():
        import datetime
        day = datetime.date.fromtimestamp(file.stat().st_mtime).isoformat()
    return day


def read(file):
    text = file.read_text(encoding="utf-8")
    m = re.match(r"---\n(.*?)\n---\n(.*)", text, re.S)
    if not m:
        raise SystemExit(f"guide/{file.name}: no heading lines")
    meta = dict((k.strip(), v.strip()) for k, v in (l.split(":", 1) for l in m.group(1).split("\n") if l.strip()))
    for key in ("title", "description", "section", "order"):
        if key not in meta:
            raise SystemExit(f"guide/{file.name}: no {key}")
    where = f"/guide/{file.stem}/"
    body, heads = markdown(m.group(2), where)
    words = len(re.sub(r"<[^>]+>", " ", body).split())
    return {**meta, "slug": file.stem, "where": where, "body": body, "heads": heads, "words": words,
            "order": int(meta["order"]), "day": changed(file)}


def guide_pages(dist, picture):
    """Writes the guide; returns its pages as (path, day last changed) for the sitemap."""
    sections = json.loads((HERE / "guide/sections.json").read_text(encoding="utf-8"))
    template = (HERE / "guide.html").read_text(encoding="utf-8")
    pages = [read(f) for f in sorted((HERE / "guide").glob("*.md"))]
    known = {s["id"] for s in sections}
    for p in pages:
        if p["section"] not in known:
            raise SystemExit(f"guide/{p['slug']}.md: no section {p['section']}")
    ordered = [p for s in sections for p in sorted((q for q in pages if q["section"] == s["id"]), key=lambda q: q["order"])]
    paths = {p["where"] for p in pages} | {"/guide/"}
    for p in pages:
        for href in re.findall(r'href="(/guide/[^"#]*)', p["body"]):
            if href not in paths:
                raise SystemExit(f"guide/{p['slug']}.md: a link to {href}, which is not a page")

    def side(current):
        groups = []
        for s in sections:
            links = "".join(f'<li><a href="{p["where"]}"{" aria-current=page" if p["where"] == current else ""}>'
                            f'{e(p.get("short", p["title"]))}</a></li>' for p in ordered if p["section"] == s["id"])
            if links:
                groups.append(f'<p class="grp">{e(s["title"])}</p><ul>{links}</ul>')
        return "".join(groups)

    def write(where, values):
        page = template
        for key, value in values.items():
            page = page.replace("{{" + key + "}}", value)
        left = re.search(r"\{\{\w+\}\}", page)
        if left:
            raise SystemExit(f"guide{where}: no value for {left.group(0)}")
        out = dist / where.strip("/") / "index.html"
        out.parent.mkdir(parents=True, exist_ok=True)
        out.write_text(picture(page), encoding="utf-8")

    for n, p in enumerate(ordered):
        section = next(s for s in sections if s["id"] == p["section"])
        before, after = (ordered[n - 1] if n else None), (ordered[n + 1] if n + 1 < len(ordered) else None)
        turn = '<nav class="turn" aria-label="Pages">' + (
            f'<a rel="prev" href="{before["where"]}"><span>Before</span>{e(before["title"])}</a>' if before else "<span></span>") + (
            f'<a rel="next" href="{after["where"]}"><span>Next</span>{e(after["title"])}</a>' if after else "") + "</nav>"
        onpage = ('<nav class="onpage" aria-label="On this page"><p class="grp">On this page</p><ul>'
                  + "".join(f'<li><a href="#{i}">{t}</a></li>' for i, t in p["heads"]) + "</ul></nav>") if len(p["heads"]) > 1 else ""
        ld = [{"@context": "https://schema.org", "@type": "TechArticle", "headline": p["title"],
               "description": p["description"], "dateModified": p["day"], "inLanguage": "en",
               "mainEntityOfPage": SITE + p["where"], "wordCount": p["words"],
               "author": {"@type": "Organization", "name": "Musset", "url": SITE + "/"},
               "publisher": {"@type": "Organization", "name": "Musset", "url": SITE + "/",
                             "logo": {"@type": "ImageObject", "url": SITE + "/assets/icon.png"}},
               "about": {"@type": "SoftwareApplication", "name": "Musset", "operatingSystem": "macOS 14 or later",
                         "applicationCategory": "Writing application"}},
              {"@context": "https://schema.org", "@type": "BreadcrumbList", "itemListElement": [
                  {"@type": "ListItem", "position": 1, "name": "Musset", "item": SITE + "/"},
                  {"@type": "ListItem", "position": 2, "name": "Guide", "item": SITE + "/guide/"},
                  {"@type": "ListItem", "position": 3, "name": p["title"], "item": SITE + p["where"]}]}]
        body = f"""<article>
<p class="crumbs"><a href="/guide/">Guide</a> <span>/</span> <a href="/guide/#{section["id"]}">{e(section["title"])}</a></p>
<h1>{e(p["title"])}</h1>
<p class="lede">{inline(p.get("lede", p["description"]))}</p>
<div class="prose">
{p["body"]}
</div>
<p class="stamp">{e(p.get("kind", "Guide"))} · Last changed {p["day"]} · <a href="https://github.com/Musset-App/musset/blob/main/website/guide/{p["slug"]}.md" rel="noopener">Correct this page</a></p>
{turn}
</article>
{onpage}"""
        write(p["where"], {"title": html.escape(p.get("seo", p["title"]) + " | Musset"),
                           "description": html.escape(p["description"], quote=True), "canonical": SITE + p["where"],
                           "side": side(p["where"]), "body": body, "layout": "page",
                           "ld": "\n".join(f'<script type="application/ld+json">{json.dumps(x, ensure_ascii=False)}</script>' for x in ld)})

    index = json.loads((HERE / "guide/index.json").read_text(encoding="utf-8"))
    parts, n = [], 0
    for s in sections:
        rows = ""
        for p in (q for q in ordered if q["section"] == s["id"]):
            n += 1
            rows += (f'<li><a href="{p["where"]}"><span class="num">{n:02d}</span><span class="what"><strong>{e(p["title"])}</strong>'
                     f'<span>{e(p["description"])}</span></span><span class="kind">{e(p.get("kind", "Guide"))}</span></a></li>')
        if rows:
            parts.append(f'<section id="{s["id"]}"><h2>{e(s["title"])}</h2><p class="blurb">{e(s["blurb"])}</p><ol class="contents">{rows}</ol></section>')
    body = f"""<article class="front">
<p class="crumbs">Guide</p>
<h1>{e(index["h1"])}</h1>
<p class="lede">{e(index["lede"])}</p>
{"".join(parts)}
</article>"""
    ld = {"@context": "https://schema.org", "@type": "CollectionPage", "name": index["title"], "url": SITE + "/guide/",
          "hasPart": [{"@type": "TechArticle", "headline": p["title"], "url": SITE + p["where"]} for p in ordered]}
    write("/guide/", {"title": html.escape(index["title"]), "description": html.escape(index["description"], quote=True),
                      "canonical": SITE + "/guide/", "side": side("/guide/"), "body": body, "layout": "index",
                      "ld": f'<script type="application/ld+json">{json.dumps(ld, ensure_ascii=False)}</script>'})
    total = sum(p["words"] for p in pages)
    print(f"en: /guide/ and {len(pages)} pages, {total} words")
    return [("/guide/", max((p["day"] for p in pages), default=""))] + [(p["where"], p["day"]) for p in ordered]
