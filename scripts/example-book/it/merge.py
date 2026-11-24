# Three-way merge of the OCRs of the 1902 Italian Time Machine.
# A  = archive.org ABBYY text (ocr.txt)
# V1 = macOS Vision with language correction (vision.txt)
# V3 = macOS Vision without language correction, with boxes (vision3.tsv)  -> backbone
import re, sys, json, unicodedata, difflib, bisect, collections, hashlib, os

D = sys.argv[1]
FIRST, LAST = 7, 179
CHAPTER_PAGES = [7, 17, 25, 37, 48, 57, 69, 81, 101, 112, 125, 138, 151, 157, 167, 170, 178]

def norm_text(s):
    s = s.replace(' ', ' ')
    s = re.sub(r"[‘’ʼ`´']", '’', s)
    s = s.replace('<<', '«').replace('>>', '»')
    s = re.sub(r'\s+', ' ', s).strip()
    return s

TOK = re.compile(r"[^\W_]+(?:-[^\W_]+)*’?|\.(?: ?\.)+|[—–―_-]+|\S")
def tokenize(s):
    out = []
    for m in TOK.finditer(s):
        t = m.group(0)
        if re.fullmatch(r"\.(?: ?\.)+", t):
            t = '…' + str(t.count('.'))
        elif re.fullmatch(r"[—–―_-]+", t):
            t = '—'
        out.append(t)
    return out

def deaccent(s):
    return ''.join(c for c in unicodedata.normalize('NFD', s) if unicodedata.category(c) != 'Mn')
def key(t):
    if t.startswith('…'): return '…'
    return deaccent(t).lower()
def isword(t):
    return bool(re.match(r"[^\W_]", t))

def upper_ratio(s):
    L = [c for c in s if c.isalpha()]
    if len(L) < 3: return 0
    return sum(c.isupper() for c in L) / len(L)
def is_pagenum(s):
    return bool(re.fullmatch(r"[\W\dlIO\]]{1,6}", s)) and len(s) <= 6
def is_roman(s):
    return bool(re.fullmatch(r"[IVXLl1T]{1,5}\.?,?", s))
def is_signature(s):
    return bool(re.search(r"(?i)un.{0,2}esplorazione nel futuro", s)) and upper_ratio(s) < 0.5

def filter_page(page, lines):
    """lines: list of dicts with 'text'. Returns body lines; drops heads, page numbers, signatures, chapter headings."""
    keep = []
    n = len(lines)
    for i, l in enumerate(lines):
        s = l['text']
        if i < 4:
            if is_pagenum(s) or upper_ratio(s) > 0.6: continue
            if page in CHAPTER_PAGES and is_roman(s): continue
        if i >= n - 3:
            if is_signature(s) or re.fullmatch(r"[\d ]{1,3}", s) or (i >= n-2 and is_pagenum(s) and len(s) <= 2): continue
        keep.append(l)
    return keep

def stream(lines):
    """lines: list of dicts(text, page, box, para). -> tokens list of dict(t, page, li, para)"""
    toks = []
    join = False
    for li, l in enumerate(lines):
        s = l['text']
        nxt = lines[li+1]['text'] if li+1 < len(lines) else ''
        j2 = False
        m = re.search(r"([^\W\d_])[-¬]$", s)
        if m and re.match(r"[^\W\d_]", nxt) and nxt[0].islower():
            s = s[:-1]; j2 = True
        elif s.endswith('¬'):
            s = s[:-1]; j2 = True
        ts = tokenize(s)
        for k, t in enumerate(ts):
            if k == 0 and join and toks and isword(toks[-1]['t']) and isword(t):
                toks[-1]['t'] += t
                continue
            toks.append({'t': t, 'page': l.get('page'), 'li': li, 'para': bool(l.get('para')) and k == 0, 'brk': l.get('pagebreak', False) and k == 0, 'unk': bool(l.get('unknown')) and k == 0})
        join = j2
    return toks

# ---------- V3
def load_v3():
    pages = collections.OrderedDict()
    p = None
    for raw in open(os.path.join(D, 'vision3.tsv'), encoding='utf-8'):
        raw = raw.rstrip('\n')
        if raw.startswith('=== page'):
            p = int(raw.split()[-1]); pages[p] = []; continue
        f = raw.split('\t', 5)
        if f[0] == 'L':
            pages[p].append({'text': norm_text(f[5]), 'box': tuple(map(float, f[1:5])), 'page': p, 'words': []})
        elif f[0] == 'W' and pages[p]:
            pages[p][-1]['words'].append((tuple(map(float, f[1:5])), f[5]))
    return pages

def mark_indents(lines):
    if not lines: return
    xs = sorted(l['box'][0] for l in lines)
    m0 = xs[max(0, len(xs)//5)]
    inl = [l for l in lines if abs(l['box'][0] - m0) < 0.015]
    a, b = m0, 0.0
    if len(inl) >= 4:
        ys = [l['box'][1] for l in inl]; xx = [l['box'][0] for l in inl]
        my = sum(ys)/len(ys); mx = sum(xx)/len(xx)
        den = sum((y-my)**2 for y in ys)
        if den > 1e-6:
            b = sum((y-my)*(x-mx) for x, y in zip(xx, ys))/den; a = mx - b*my
    rs = sorted(l['box'][0] + l['box'][2] for l in lines)
    rm = rs[min(len(rs)-1, (len(rs)*7)//10)]
    for l in lines:
        l['indent'] = l['box'][0] - (a + b*l['box'][1])
        l['para'] = l['indent'] > 0.02
        l['short'] = (l['box'][0] + l['box'][2]) < rm - 0.07

def v3_lines():
    pages = load_v3()
    out = []
    for p in range(FIRST, LAST+1):
        body = filter_page(p, pages.get(p, []))
        mark_indents(body)
        if body:
            body[0]['pagebreak'] = True
            if p in CHAPTER_PAGES: body[0]['chapter'] = True; body[0]['para'] = True
        out += body
    for i in range(1, len(out)):
        if out[i-1].get('short') and re.search(r'[.!?:»…—-]$', out[i-1]['text']) and not out[i]['para']:
            out[i]['para'] = True; out[i]['para_short'] = True
    return out

def v1_lines():
    pages = collections.OrderedDict(); p = None
    for raw in open(os.path.join(D, 'vision.txt'), encoding='utf-8'):
        raw = raw.rstrip('\n')
        if raw.startswith('=== page'):
            p = int(raw.split()[-1]); pages[p] = []; continue
        if raw.strip(): pages[p].append({'text': norm_text(raw), 'page': p})
    out = []
    for p in range(FIRST, LAST+1):
        out += filter_page(p, pages.get(p, []))
    return out

def a_lines():
    L = open(os.path.join(D, 'ocr.txt'), encoding='utf-8').read().split('\n')
    # body: from first 'INTRODUZIONE.' to 'INDICE'
    start = next(i for i, l in enumerate(L) if l.strip() == 'I.')
    end = next(i for i, l in enumerate(L) if l.strip() == 'INDICE')
    out = []; blank = True; headgap = False
    for l in L[start:end]:
        s = norm_text(l)
        if not s:
            blank = True; continue
        if is_pagenum(s) or upper_ratio(s) > 0.6 or is_roman(s) or (is_signature(s) and len(s) < 34) or re.search(r"(?i)^un.{0,3}esplorazione\s+nel\s+futuro", s):
            headgap = True; continue
        out.append({'text': s, 'para': blank and not headgap, 'unknown': blank and headgap})
        blank = False; headgap = False
    return out

# ---------- alignment
def lis(seq):
    # longest increasing subsequence on list of (i,j) sorted by i; returns subset increasing in j
    tails = []; idx = []; prev = [-1]*len(seq)
    for n, (i, j) in enumerate(seq):
        k = bisect.bisect_left(tails, j)
        if k == len(tails): tails.append(j); idx.append(n)
        else: tails[k] = j; idx[k] = n
        prev[n] = idx[k-1] if k > 0 else -1
    out = []; n = idx[-1] if idx else -1
    while n >= 0: out.append(seq[n]); n = prev[n]
    return out[::-1]

def align(a, b):
    """opcodes (tag,i1,i2,j1,j2) between key lists a and b, anchored on unique trigrams."""
    def grams(x):
        d = collections.defaultdict(list)
        for i in range(len(x)-2): d[(x[i], x[i+1], x[i+2])].append(i)
        return d
    ga, gb = grams(a), grams(b)
    pairs = sorted((v[0], gb[k][0]) for k, v in ga.items() if len(v) == 1 and len(gb.get(k, ())) == 1)
    anchors = lis(pairs)
    ops = []
    pi = pj = 0
    def sub(i1, i2, j1, j2):
        if i1 == i2 and j1 == j2: return
        sm = difflib.SequenceMatcher(None, a[i1:i2], b[j1:j2], autojunk=False)
        for tag, x1, x2, y1, y2 in sm.get_opcodes():
            ops.append((tag, i1+x1, i1+x2, j1+y1, j1+y2))
    for (i, j) in anchors:
        if i < pi or j < pj: continue
        sub(pi, i, pj, j)
        ops.append(('equal', i, i+1, j, j+1))
        pi, pj = i+1, j+1
    sub(pi, len(a), pj, len(b))
    return ops

def build():
    L3 = v3_lines(); T3 = stream(L3)
    T1 = stream(v1_lines())
    TA = stream(a_lines())
    k3 = [key(t['t']) for t in T3]; k1 = [key(t['t']) for t in T1]; kA = [key(t['t']) for t in TA]
    def mapping(kx):
        # for each backbone index: matched other index or None; plus bound arrays
        m = [None]*len(k3)
        for tag, i1, i2, j1, j2 in align(k3, kx):
            if tag == 'equal':
                for d in range(i2-i1): m[i1+d] = j1+d
        return m
    mA = mapping(kA); m1 = mapping(k1)
    regions = []  # list of ('eq', i, ia, i1) or ('diff', (s,e), (as,ae), (1s,1e))
    s = 0; pa = 0; p1 = 0
    n = len(T3)
    i = 0
    while i <= n:
        stable = i < n and mA[i] is not None and m1[i] is not None
        if stable or i == n:
            ea = mA[i] if i < n else len(TA); e1 = m1[i] if i < n else len(T1)
            if i > s or ea > pa or e1 > p1:
                regions.append(('diff', (s, i), (pa, ea), (p1, e1)))
            if i < n:
                regions.append(('eq', i, mA[i], m1[i]))
                pa = mA[i]+1; p1 = m1[i]+1
            s = i+1
        i += 1
    return L3, T3, T1, TA, regions

if __name__ == '__main__':
    L3, T3, T1, TA, regions = build()
    print(len(T3), len(T1), len(TA), len(regions), sum(r[0] == 'diff' for r in regions))
    import pickle
    pickle.dump((L3, T3, T1, TA, regions), open(os.path.join(D, 'merge.pkl'), 'wb'))
