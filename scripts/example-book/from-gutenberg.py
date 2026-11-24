#!/usr/bin/env python3
"""Turns a Project Gutenberg plain text of The Time Machine into the Markdown Musset's example book is made from:
one `# Title` per chapter, one paragraph per block, italics as *…*, without Gutenberg's own header and licence.

    scripts/example-book/from-gutenberg.py 35-0.txt > Musset/Resources/Example/example-time-machine-en.md
"""
import re, sys

text = open(sys.argv[1], encoding="utf-8-sig").read().replace("\r", "")
start = re.search(r"\*\*\* START OF .*?\*\*\*", text).end()
end = re.search(r"\*\*\* END OF ", text).start()
lines = text[start:end].split("\n")

chapters, title, block, blocks = [], None, [], []
def flush_block():
    global block
    if block: blocks.append(" ".join(l.strip() for l in block)); block = []
def flush_chapter():
    global blocks
    flush_block()
    if title is not None: chapters.append((title, blocks))
    blocks = []

i = 0
while i < len(lines):
    line = lines[i]
    if re.fullmatch(r" ?[IVXL]+\.", line.rstrip()) and i + 1 < len(lines) and lines[i + 1].strip():
        flush_chapter()
        title = lines[i + 1].strip()
        i += 2
        continue
    if line.strip() == "Epilogue" and title is not None:
        flush_chapter()
        title = "Epilogue"
    elif title is not None:
        if line.strip(): block.append(line)
        else: flush_block()
    i += 1
flush_chapter()

out = []
for title, blocks in chapters:
    out.append("# " + title)
    for b in blocks:
        b = re.sub(r"_([^_]+)_", r"*\1*", b)
        # Gutenberg sets a footnote in the line: « [Footnote: …] ».
        notes = []
        def note(m):
            notes.append(m.group(1).strip())
            return "[^%d]" % len(notes)
        b = re.sub(r" ?\[Footnote: ([^\]]*)\]", note, b)
        out.append(b)
        out += ["[^%d]: %s" % (n + 1, t) for n, t in enumerate(notes)]
print("\n\n".join(out))
