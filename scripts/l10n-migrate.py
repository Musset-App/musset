#!/usr/bin/env python3
"""Moves Musset's interface text from L("en", "fr") pairs to L("en") keys plus a French table.

    python3 -I scripts/l10n-migrate.py [--write]

Without --write it only reports. It rewrites:
  L("english", "français")                     -> L("english")
  L("\\(n) words", "\\(n) mots")               -> L("\\(n) words")       key "{%0} words"
  L(c ? "a" : "b", c ? "x" : "y")              -> (c ? L("a") : L("b"))
and lists every other L( call for a hand fix. The French goes to Musset/Resources/Localization/fr.json,
merged with what is already there. `--keys` prints every key found in the sources (for the tests).
"""
import json, os, re, sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SRC = os.path.join(ROOT, "Musset")
TABLES = os.path.join(SRC, "Resources", "Localization")

def decode(s):
    """A Swift literal's text (escapes only; interpolations are handled by the caller)."""
    out, i = [], 0
    while i < len(s):
        c = s[i]
        if c == "\\" and i + 1 < len(s):
            n = s[i + 1]
            if n == "u" and s[i + 2:i + 3] == "{":
                j = s.index("}", i)
                out.append(chr(int(s[i + 3:j], 16))); i = j + 1; continue
            out.append({"n": "\n", "t": "\t", "0": "\0", "r": "\r", '"': '"', "'": "'", "\\": "\\"}.get(n, n)); i += 2; continue
        out.append(c); i += 1
    return "".join(out)

class Lexer:
    def __init__(self, text): self.t = text

    def string_end(self, i):
        """i at the opening quote (or #). Returns (end index after literal, segments) or raises."""
        t = self.t
        hashes = 0
        while t[i] == "#": hashes += 1; i += 1
        assert t[i] == '"'
        multi = t.startswith('"""', i)
        q = '"""' if multi else '"'
        i += len(q)
        close = q + "#" * hashes
        esc = "\\" + "#" * hashes
        segs, buf = [], []
        while True:
            if t.startswith(close, i):
                segs.append(("text", "".join(buf)))
                return i + len(close), segs, hashes, multi
            if t.startswith(esc + "(", i):
                segs.append(("text", "".join(buf))); buf = []
                j = self.balanced(i + len(esc))
                segs.append(("expr", t[i + len(esc) + 1:j - 1]))
                i = j; continue
            if hashes == 0 and t[i] == "\\":
                buf.append(t[i:i + 2]); i += 2; continue
            if not multi and t[i] == "\n": raise ValueError("unterminated string")
            buf.append(t[i]); i += 1

    def balanced(self, i):
        """i at '('. Returns the index after the matching ')'."""
        t, depth = self.t, 0
        while i < len(t):
            c = t[i]
            if c in "([{": depth += 1
            elif c in ")]}":
                depth -= 1
                if depth == 0: return i + 1
            elif c == '"' or (c == "#" and re.match(r'#+"', t[i:])):
                i = self.string_end(i)[0]; continue
            elif t.startswith("//", i): i = t.index("\n", i); continue
            elif t.startswith("/*", i): i = t.index("*/", i) + 2; continue
            i += 1
        raise ValueError("unbalanced")

    def split_args(self, start, end):
        """Top-level comma split of t[start:end]."""
        t, parts, depth, i, s = self.t, [], 0, start, start
        while i < end:
            c = t[i]
            if c in "([{": depth += 1
            elif c in ")]}": depth -= 1
            elif c == '"' or (c == "#" and re.match(r'#+"', t[i:])):
                i = self.string_end(i)[0]; continue
            elif c == "," and depth == 0:
                parts.append((s, i)); s = i + 1
            i += 1
        parts.append((s, end))
        return parts

    def calls(self):
        """Every L( call in code: (start, open paren index, end)."""
        t, i, out = self.t, 0, []
        while i < len(t):
            c = t[i]
            if t.startswith("//", i): i = t.find("\n", i); i = len(t) if i < 0 else i; continue
            if t.startswith("/*", i): i = t.index("*/", i) + 2; continue
            if c == '"' or (c == "#" and re.match(r'#+"', t[i:])):
                i = self.string_end(i)[0]; continue
            if c == "L" and t[i + 1:i + 2] == "(" and (i == 0 or not re.match(r"[\w.]", t[i - 1])):
                end = self.balanced(i + 1)
                out.append((i, i + 1, end))
                i += 2; continue
            i += 1
        return out

def literal(lex, src_start, src_end):
    """The literal spanning exactly t[src_start:src_end] (stripped), as (source, segments) or None."""
    t = lex.t
    s = src_start
    while t[s].isspace(): s += 1
    e = src_end
    while t[e - 1].isspace(): e -= 1
    if not (t[s] == '"' or t[s] == "#"): return None
    try:
        end, segs, hashes, multi = lex.string_end(s)
    except Exception:
        return None
    if end != e or hashes or multi: return None
    return t[s:e], segs

def key_of(segs):
    """Runtime key: text with {%i} for each interpolation, and the list of expressions."""
    key, exprs = "", []
    for kind, v in segs:
        if kind == "text": key += decode(v)
        else: key += "{%" + str(len(exprs)) + "}"; exprs.append(v.strip())
    return key, exprs

def french_value(en_exprs, fr_segs):
    out = ""
    for kind, v in fr_segs:
        if kind == "text": out += decode(v)
        else:
            e = v.strip()
            if e not in en_exprs: return None
            out += "{%" + str(en_exprs.index(e)) + "}"
    return out

TERNARY = re.compile(r"^\s*(?P<c>[^?\"]+?)\s*\?\s*(?P<a>\"(?:[^\"\\]|\\.)*\")\s*:\s*(?P<b>\"(?:[^\"\\]|\\.)*\")\s*$", re.S)

def main():
    # First pass: English keys whose French differs from one place to another need a context,
    # given as the French sense: L("Done", ctx: "Terminé").
    senses = {}
    def collect(k, v): senses.setdefault(k, set()).add(v)
    scan(collect=collect)
    ambiguous = {k for k, v in senses.items() if len(v) > 1}
    scan(ambiguous=ambiguous)

def scan(collect=None, ambiguous=frozenset()):
    write = "--write" in sys.argv and collect is None
    list_keys = "--keys" in sys.argv
    fr_path = os.path.join(TABLES, "fr.json")
    fr = json.load(open(fr_path, encoding="utf-8")) if os.path.exists(fr_path) else {}
    conflicts, manual, keys, count = [], [], set(), 0
    for dirpath, _, files in os.walk(SRC):
        if "/Resources" in dirpath: continue
        for name in files:
            if not name.endswith(".swift"): continue
            path = os.path.join(dirpath, name)
            text = open(path, encoding="utf-8").read()
            lex = Lexer(text)
            edits = []
            for start, paren, end in lex.calls():
                args = lex.split_args(paren + 1, end - 1)
                line = text.count("\n", 0, start) + 1
                rel = os.path.relpath(path, ROOT)
                ctx = []
                def record(en_segs, fr_segs):
                    k, exprs = key_of(en_segs)
                    if fr_segs is None: keys.add(k); return True
                    v = french_value(exprs, fr_segs)
                    if v is None: return False
                    if collect: collect(k, v); return True
                    if k in ambiguous:
                        ctx.append(v); k = k + "@@" + v
                    keys.add(k)
                    if k in fr and fr[k] != v and not isinstance(fr[k], dict):
                        conflicts.append(f"{rel}:{line}: {k!r}: {fr[k]!r} vs {v!r}")
                    else:
                        fr.setdefault(k, v)
                    return True
                def call(lit):
                    if not ctx: return "L(" + lit + ")"
                    return "L(" + lit + ", ctx: " + json.dumps(ctx.pop(0), ensure_ascii=False) + ")"
                if len(args) == 1:
                    lit = literal(lex, *args[0])
                    if lit: keys.add(key_of(lit[1])[0]); continue
                    manual.append(f"{rel}:{line}: {text[start:end][:120]!r}"); continue
                second = text[args[1][0]:args[1][1]].strip() if len(args) == 2 else ""
                if second.startswith("ctx:"):
                    lit = literal(lex, *args[0])
                    m = re.match(r'ctx:\s*("(?:[^"\\]|\\.)*")$', second)
                    if lit and m:
                        keys.add(key_of(lit[1])[0] + "@@" + decode(m.group(1)[1:-1])); continue
                if len(args) == 2:
                    en, frl = literal(lex, *args[0]), literal(lex, *args[1])
                    if en and frl:
                        if record(en[1], frl[1]):
                            edits.append((start, end, call(en[0]))); count += 1; continue
                    a, b = TERNARY.match(text[args[0][0]:args[0][1]]), TERNARY.match(text[args[1][0]:args[1][1]])
                    if a and b and a["c"].strip() == b["c"].strip():
                        ea, eb = Lexer(a["a"]), Lexer(a["b"])
                        fa, fb = Lexer(b["a"]), Lexer(b["b"])
                        sa, sb = ea.string_end(0)[1], eb.string_end(0)[1]
                        ok = record(sa, fa.string_end(0)[1]) and record(sb, fb.string_end(0)[1])
                        if ok:
                            edits.append((start, end, f"({a['c'].strip()} ? {call(a['a'])} : {call(a['b'])})")); count += 1; continue
                manual.append(f"{rel}:{line}: {text[start:end][:160]!r}")
            if write and edits:
                for s, e, r in sorted(edits, reverse=True):
                    text = text[:s] + r + text[e:]
                open(path, "w", encoding="utf-8").write(text)
    if collect: return
    if list_keys:
        for k in sorted(keys): print(json.dumps(k, ensure_ascii=False))
        return
    if write:
        os.makedirs(TABLES, exist_ok=True)
        json.dump(dict(sorted(fr.items())), open(fr_path, "w", encoding="utf-8"), ensure_ascii=False, indent=1)
    print(f"rewritten: {count}  keys: {len(keys)}  french: {len(fr)}")
    print(f"conflicts ({len(conflicts)}):"); print("\n".join(conflicts))
    print(f"manual ({len(manual)}):"); print("\n".join(manual))

main()
