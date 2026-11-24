#!/usr/bin/env python3
"""Makes the French text of Musset's example book: « La Machine à explorer le temps », translated by
Henry-D. Davray (1873-1944), as Mercure de France printed it in 1898-99 and Wikisource transcribed it.

    scripts/example-book/from-wikisource-fr.py <folder> > Musset/Resources/Example/example-time-machine-fr.md

<folder> holds ch1.json … ch17.json, each the answer of
https://fr.wikisource.org/w/api.php?action=parse&page=La_Machine_à_explorer_le_temps/<n>&prop=text&format=json&formatversion=2
"""
import json, re, sys
from html.parser import HTMLParser

class Page(HTMLParser):
    SKIP = {"ws-noexport", "headertemplate", "pagenum", "reference", "mw-editsection", "noprint", "mw-references-wrap", "references", "footertemplate"}
    BLOCK = {"p", "div", "h1", "h2", "h3", "h4", "center", "li", "br"}
    def __init__(self):
        super().__init__(convert_charrefs=True)
        self.blocks, self.cur, self.skip, self.stack = [], "", 0, []
    def flush(self):
        t = re.sub(r"\s+", " ", self.cur).strip()
        if t: self.blocks.append(t)
        self.cur = ""
    def handle_starttag(self, tag, attrs):
        a = dict(attrs)
        cls = set((a.get("class") or "").split()) | {a.get("id") or ""}
        skipping = self.skip or bool(cls & self.SKIP) or tag in ("style", "script", "sup")
        if tag not in ("br", "img", "link", "meta", "hr", "input"): self.stack.append(skipping)
        if skipping and not self.skip and tag not in ("br", "img", "link", "meta", "hr", "input"): self.skip = len(self.stack)
        if self.skip: return
        if tag in self.BLOCK: self.flush()
        if tag in ("i", "em"): self.cur += "*"
    def handle_endtag(self, tag):
        if tag in ("br", "img", "link", "meta", "hr", "input"): return
        if not self.skip:
            if tag in ("i", "em"): self.cur += "*"
            if tag in self.BLOCK: self.flush()
        if self.stack:
            self.stack.pop()
            if self.skip and len(self.stack) < self.skip: self.skip = 0
    def handle_data(self, data):
        if not self.skip: self.cur += data

def clean(t):
    t = t.replace(" ", " ").replace(" ", " ")
    t = re.sub(r"\*\s*\*", "", t)                    # an italic that opens and closes on nothing
    t = re.sub(r"\*(\s+)", r"\1*", t) if False else t
    t = re.sub(r" +", " ", t).strip()
    # French spacing, as Musset keeps it: a no-break space before ; : ! ? » and after «.
    t = re.sub(r" ([;:!?»])", " \\1", t)
    t = re.sub(r"« ", "« ", t)
    return t

# The review set its titles in capitals: the names in them get theirs back.
TITLES = {"Les morlocks": "Les Morlocks", "L’explorateur revient": "L’Explorateur revient", "Le retour de l’explorateur": "Le Retour de l’Explorateur",
          "La trappe du sphinx blanc": "La Trappe du Sphinx Blanc", "Le palais de porcelaine verte": "Le Palais de Porcelaine Verte",
          "La machine": "La Machine", "Dans l’âge d’or": "Dans l’Âge d’or"}

folder = sys.argv[1]
out = []
for n in range(1, 18):
    page = Page()
    page.feed(json.load(open(f"{folder}/ch{n}.json"))["parse"]["text"])
    page.flush()
    blocks = [clean(b) for b in page.blocks]
    blocks = [b for b in blocks if b]
    # The chapter opens with its number (the first has none), then its title in capitals.
    i = next(k for k, b in enumerate(blocks) if b.isupper() and not re.fullmatch(r"[IVXL]+\.?", b))
    title = blocks[i]
    title = title[0] + title[1:].lower()
    i -= 1
    title = TITLES.get(title.rstrip("."), title.rstrip("."))
    out.append("# " + title)
    # Not the review's own lines: « (À suivre.) », the translator's signature.
    out += [b for b in blocks[i + 2:] if not re.fullmatch(r"\(?(À suivre|A suivre|Fin|Traduit de l’anglais)[^)]*\)?\.?|H\.-G\. Wells\.?", b, re.I)]
print("\n\n".join(out))
