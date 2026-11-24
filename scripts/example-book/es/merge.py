# Merges three readings of the 1925 Spanish Time Machine (a.tsv backbone, b.tsv, c.tsv), word by word.
# Writes draft.md (with [pN] page marks), open.txt (places where no two readings agree) and stats.
#   merge.py <dir>
import re, sys, os, json, unicodedata, difflib, bisect, collections, hashlib

D = sys.argv[1]

def norm_text(s):
    s = s.replace(' ', ' ')
    s = re.sub(r"[‘’ʼ`´']", '’', s)
    s = s.replace('<<', '«').replace('>>', '»')
    return re.sub(r'\s+', ' ', s).strip()

def load(name):
    pages = collections.OrderedDict(); p = None
    for raw in open(os.path.join(D, name), encoding='utf-8'):
        raw = raw.rstrip('\n')
        if raw.startswith('=== page'):
            p = int(raw.split()[-1]); pages[p] = []; continue
        f = raw.split('\t', 5)
        if f[0] == 'L':
            pages[p].append({'text': norm_text(f[5]), 'box': tuple(map(float, f[1:5])), 'page': p})
    for p, ls in pages.items():
        ls.sort(key=lambda l: -(l['box'][1] + l['box'][3] / 2))
        rows = []
        for l in ls:
            mid = l['box'][1] + l['box'][3] / 2
            if rows and abs(rows[-1][0] - mid) < 0.009 and 'win10' not in l['text'] and 'win10' not in rows[-1][1][-1]['text']:
                rows[-1][1].append(l)
            else: rows.append([mid, [l]])
        out = []
        for mid, r in rows:
            r.sort(key=lambda l: l['box'][0])
            x0 = r[0]['box'][0]; y0 = min(l['box'][1] for l in r)
            x1 = max(l['box'][0] + l['box'][2] for l in r); y1 = max(l['box'][1] + l['box'][3] for l in r)
            out.append({'text': ' '.join(l['text'] for l in r), 'box': (x0, y0, x1 - x0, y1 - y0), 'page': p})
        pages[p] = out
    return pages

def upper_ratio(s):
    L = [c for c in s if c.isalpha()]
    return sum(c.isupper() for c in L) / len(L) if len(L) >= 3 else 0

def is_pagenum(l):
    s = l['text']
    return l['box'][1] > 0.80 and len(s) <= 12 and bool(re.search(r'\d', s)) and not re.search(r'[a-záéíóúñ]{3}', s)

def is_junk(l):
    s = l['text']
    if 'win10' in s or 'http' in s: return True
    if len(s) <= 2 and not re.search(r'[A-Za-zÁÉÍÓÚáéíóúñ¿¡—]', s): return True
    return False

A, B, C = load('a.tsv'), load('b.tsv'), load('c.tsv')

# Chapter openings: the page with a CAPITULO line (or EPILOGO); the title is the next line.
chapters = {}   # page -> title as read
first = last = None
for p, lines in A.items():
    for i, l in enumerate(lines):
        s = l['text']
        if re.match(r'CAP[IÍ]TULO\b', s) and upper_ratio(s) > 0.8 and p not in chapters:
            chapters[p] = lines[i + 1]['text'] if i + 1 < len(lines) else ''
            if first is None: first = p
        if re.fullmatch(r'EP[IÍ]LOGO\.?', s) and first and p not in chapters and p > 100:
            chapters[p] = 'Epílogo'
        if re.fullmatch(r'[IÍ]NDICE\.?', s) and first and last is None and p > 100: last = p - 1
print('body pages', first, last, 'chapters', len(chapters), file=sys.stderr)
json.dump({str(k): v for k, v in chapters.items()}, open(os.path.join(D, 'chapters.json'), 'w'), ensure_ascii=False, indent=1)

def body(pages, p, heads):
    """The text lines of a page: no watermark, page number, ornament, chapter head."""
    out = []; skip_title = False
    lines = pages.get(p, [])
    for i, l in enumerate(lines):
        s = l['text']
        if is_junk(l) or is_pagenum(l): continue
        if p in heads:
            if re.match(r'CAP[IÍ]TULO\b', s) and upper_ratio(s) > 0.8: skip_title = True; continue
            if re.fullmatch(r'EP[IÍ]LOGO\.?', s): continue
            if skip_title: skip_title = False; continue
            if upper_ratio(s) > 0.8 and len(s) < 30 and l['box'][1] > 0.45: continue
        out.append(l)
    return out

def mark_indents(lines):
    if not lines: return
    xs = sorted(l['box'][0] for l in lines)
    m0 = xs[max(0, len(xs) // 5)]
    inl = [l for l in lines if abs(l['box'][0] - m0) < 0.015]
    a, b = m0, 0.0
    if len(inl) >= 4:
        ys = [l['box'][1] for l in inl]; xx = [l['box'][0] for l in inl]
        my = sum(ys) / len(ys); mx = sum(xx) / len(xx)
        den = sum((y - my) ** 2 for y in ys)
        if den > 1e-6:
            b = sum((y - my) * (x - mx) for x, y in zip(xx, ys)) / den; a = mx - b * my
    for l in lines:
        l['indent'] = l['box'][0] - (a + b * l['box'][1])
        l['para'] = l['indent'] > 0.016

TOK = re.compile(r"[^\W_]+(?:-[^\W_]+)*|\.(?: ?\.)+|[—–―-]+|\S")
def tokens(pages, with_layout):
    out = []; join = False
    seq = []
    for p in range(first, last + 1):
        ls = body(pages, p, chapters)
        if with_layout:
            mark_indents(ls)
            if ls and p in chapters: ls[0]['para'] = True; ls[0]['chapter'] = p
        seq += ls
    for li, l in enumerate(seq):
        s = l['text']
        nxt = seq[li + 1]['text'] if li + 1 < len(seq) else ''
        j2 = False
        if re.search(r"[^\W\d_][-¬*•·=~]$", s) and nxt[:1].islower():
            s = s[:-1]; j2 = True
        k = 0
        for m in TOK.finditer(s):
            t = m.group(0)
            if re.fullmatch(r"\.(?: ?\.)+", t): t = '…'
            elif re.fullmatch(r"[—–―-]+", t): t = '—'
            space = m.start() == 0 or s[m.start() - 1] == ' '
            if k == 0 and join and out and re.match(r"[^\W_]", out[-1]['t']) and re.match(r"[^\W_]", t):
                out[-1]['brk'] = len(out[-1]['t']); out[-1]['next'] = {'page': l['page'], 'y': l['box'][1]}
                out[-1]['t'] += t; k += 1; continue
            out.append({'t': t, 'page': l['page'], 'sp': space, 'first': k == 0, 'para': bool(l.get('para')) and k == 0,
                        'chapter': l.get('chapter') if k == 0 else None, 'y': l['box'][1]})
            k += 1
        join = j2
    return out

def deaccent(s): return ''.join(c for c in unicodedata.normalize('NFD', s) if unicodedata.category(c) != 'Mn')
def key(t): return deaccent(t).lower()

def lis(seq):
    tails = []; idx = []; prev = [-1] * len(seq)
    for n, (i, j) in enumerate(seq):
        k = bisect.bisect_left(tails, j)
        if k == len(tails): tails.append(j); idx.append(n)
        else: tails[k] = j; idx[k] = n
        prev[n] = idx[k - 1] if k > 0 else -1
    out = []; n = idx[-1] if idx else -1
    while n >= 0: out.append(seq[n]); n = prev[n]
    return out[::-1]

def align(a, b):
    def grams(x):
        d = collections.defaultdict(list)
        for i in range(len(x) - 2): d[(x[i], x[i + 1], x[i + 2])].append(i)
        return d
    ga, gb = grams(a), grams(b)
    pairs = sorted((v[0], gb[k][0]) for k, v in ga.items() if len(v) == 1 and len(gb.get(k, ())) == 1)
    ops = []; pi = pj = 0
    def sub(i1, i2, j1, j2):
        if i1 == i2 and j1 == j2: return
        sm = difflib.SequenceMatcher(None, a[i1:i2], b[j1:j2], autojunk=False)
        for tag, x1, x2, y1, y2 in sm.get_opcodes(): ops.append((tag, i1 + x1, i1 + x2, j1 + y1, j1 + y2))
    for (i, j) in lis(pairs):
        if i < pi or j < pj: continue
        sub(pi, i, pj, j); ops.append(('equal', i, i + 1, j, j + 1)); pi, pj = i + 1, j + 1
    sub(pi, len(a), pj, len(b))
    return ops

TA, TB, TC = tokens(A, True), tokens(B, False), tokens(C, False)
kA = [t['t'] for t in TA]
def mapping(T):
    m = [None] * len(TA)
    for tag, i1, i2, j1, j2 in align(kA, [t['t'] for t in T]):
        if tag == 'equal':
            for d in range(i2 - i1): m[i1 + d] = j1 + d
    return m
mB, mC = mapping(TB), mapping(TC)

# Regions: runs of backbone tokens where not all three agree exactly.
DEC = {}
dp = os.path.join(D, 'decisions.json')
if os.path.exists(dp): DEC = json.load(open(dp, encoding='utf-8'))
out = []; opens = []; stats = collections.Counter()
n = len(TA); s = 0; pb = pc = 0; i = 0
def emit(toks, like):
    for k, t in enumerate(toks):
        d = dict(like if k == 0 else {'page': like['page'], 'sp': True, 'para': False, 'chapter': None, 'first': False, 'y': like['y']})
        d['t'] = t; out.append(d)
while i <= n:
    stable = i < n and mB[i] is not None and mC[i] is not None
    if stable or i == n:
        eb = mB[i] if i < n else len(TB); ec = mC[i] if i < n else len(TC)
        if i > s or eb > pb or ec > pc:
            a = [t['t'] for t in TA[s:i]]; b = [t['t'] for t in TB[pb:eb]]; c = [t['t'] for t in TC[pc:ec]]
            like = TA[s] if s < i else {'page': TA[min(s, n - 1)]['page'], 'sp': True, 'para': False, 'chapter': None, 'first': False, 'y': TA[min(s, n - 1)]['y']}
            ctx = ' '.join(kA[max(0, s - 6):s]) + ' [' + ' '.join(a) + '] ' + ' '.join(kA[i:i + 6])
            h = hashlib.sha1((ctx + '|' + ' '.join(b) + '|' + ' '.join(c)).encode()).hexdigest()[:7]
            if h in DEC:
                d = DEC[h]; stats['decided'] += 1
                pick = a if d == 'A' else b if d == 'B' else c if d == 'C' else [] if d == '-' else d[1:].split(' ')
            elif a == c: pick = a; stats['A=C'] += 1
            elif a == b: pick = a; stats['A=B'] += 1
            elif b == c: pick = b; stats['B=C'] += 1
            else:
                pick = a; stats['open'] += 1
                opens.append('%s p%d y%.3f\n  A: %s\n  B: %s\n  C: %s\n  %s' % (h, like['page'], like['y'], ' '.join(a), ' '.join(b), ' '.join(c), ctx))
            # layout flags of the backbone survive a replacement
            if pick:
                k0 = len(out)
                emit(pick, like)
                if len(pick) == i - s:
                    for d, t in enumerate(TA[s:i]):
                        o = out[k0 + d]
                        if d: o['first'] = t['first']; o['sp'] = t['sp']; o['page'] = t['page']; o['y'] = t['y']; o['para'] = t['para']; o['chapter'] = t['chapter']
                        if 'brk' in t: o['brk'] = min(t['brk'], max(1, len(o['t']) - 1)); o['next'] = t['next']
                else:
                    for t in TA[s:i]:
                        if 'brk' in t: stats['lost line break'] += 1
                if s < i:
                    for t in TA[s + 1:i]:
                        if t['para'] or t['chapter']: out[-1]['para'] = out[-1]['para'] or t['para']
        if i < n: out.append(dict(TA[i])); stats['same'] += 1; pb = mB[i] + 1; pc = mC[i] + 1
        s = i + 1
    i += 1

json.dump(out, open(os.path.join(D, 'resolved.json'), 'w'), ensure_ascii=False)
open(os.path.join(D, 'open.txt'), 'w', encoding='utf-8').write('\n'.join(opens) + '\n')
print(dict(stats), 'tokens', len(TA), len(TB), len(TC), file=sys.stderr)
