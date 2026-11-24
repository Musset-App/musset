# Merge of the readings of the 1904 German Time Machine (Greve, Bruns).
# V3 = Vision, no language correction, 2400px (backbone: page, line, boxes)
# V1 = Vision with language correction; V36 = no correction at 3600px; R2 = Vision revision 2 (older model)
# REF = modern ebook of the same translation: comparison only, never a source.
import re, sys, os, json, unicodedata, difflib, bisect, collections, pickle
D = sys.argv[1]
FIRST, LAST = 10, 184
CHAPTER_PAGES = [10, 21, 29, 40, 51, 60, 72, 84, 106, 117, 130, 143, 156, 162, 172, 175, 183]
NAMES = ['v3', 'v1', 'v36', 'r2']

def norm_text(s):
    s = s.replace(' ', ' ')
    s = re.sub(r"[‘’ʼ`´']", '’', s)
    s = s.replace('<<', '«').replace('>>', '»').replace('›', '»').replace('‹', '«')
    s = s.replace('„', '‚').replace('“', '’').replace('”', '’').replace('"', '’')
    s = re.sub(r'\s+', ' ', s).strip()
    # opening low quote: a comma glued to the following letter, after a space or at line start
    s = re.sub(r"(^|(?<=\s))[,‚](?=[^\W\d_])", '‚', s)
    return s

TOK = re.compile(r"[^\W_]+(?:[-’][^\W_]+)*(?:-(?=\s+(?:und|oder|bis)\b))?’?|\.(?: ?\.)+|[—–―_-]+|\S")
def tokenize(s):
    out = []
    for m in TOK.finditer(s):
        t = m.group(0)
        if re.fullmatch(r"\.(?: ?\.)+", t): t = '…' + str(t.count('.'))
        elif re.fullmatch(r"[—–―_-]+", t): t = '—'
        out.append(t)
    return out
def deaccent(s):
    return ''.join(c for c in unicodedata.normalize('NFD', s) if unicodedata.category(c) != 'Mn')
def key(t):
    if t.startswith('…'): return '…'
    return deaccent(t).lower().replace('ß', 'ss')
def isword(t): return bool(re.match(r"[^\W_]", t))

def load(name):
    pages = collections.OrderedDict(); p = None
    for raw in open(os.path.join(D, name + '.tsv'), encoding='utf-8'):
        raw = raw.rstrip('\n')
        if raw.startswith('=== page'):
            p = int(raw.split()[-1]); pages[p] = []; continue
        f = raw.split('\t', 5)
        if f[0] == 'L':
            pages[p].append({'text': norm_text(f[5]), 'raw': f[5], 'box': tuple(map(float, f[1:5])), 'page': p})
    return pages

def merge_rows(body):
    """Vision sometimes splits the last word of a line into its own 'line'; put pieces of one printed row back together, left to right."""
    body = sorted(body, key=lambda l: -(l['box'][1] + l['box'][3] / 2))
    rows = []
    for l in body:
        cy = l['box'][1] + l['box'][3] / 2
        if rows and abs(rows[-1][0] - cy) < 0.010: rows[-1][1].append(l)
        else: rows.append([cy, [l]])
    out = []
    for cy, ls in rows:
        if len(ls) == 1: out.append(ls[0]); continue
        ls.sort(key=lambda l: l['box'][0])
        x0 = min(l['box'][0] for l in ls); y0 = min(l['box'][1] for l in ls)
        x1 = max(l['box'][0] + l['box'][2] for l in ls); y1 = max(l['box'][1] + l['box'][3] for l in ls)
        m = dict(ls[0]); m['text'] = ' '.join(l['text'] for l in ls); m['raw'] = ' '.join(l['raw'] for l in ls); m['box'] = (x0, y0, x1 - x0, y1 - y0); m['rowmerged'] = True
        out.append(m)
    return out

TITLES = ['Einführung', 'Die Maschine', 'Der Zeitreisende kehrt zurück', 'Das Reisen in der Zeit', 'In der goldenen Zeit', 'Der Sonnenuntergang der Menschheit',
          'Ein plötzlicher Schlag', 'Erklärung', 'Die Morlocken', 'Als die Nacht kam', 'Der grüne Porzellanpalast', 'Im Dunkel', 'Die Falle in der weissen Sphinx',
          'Die weitere Vision', 'Die Rückkehr des Zeitreisenden', 'Nach der Erzählung', 'Epilog']
def is_head(text, p):
    t = TITLES[CHAPTER_PAGES.index(p)]
    return len(text) < 7 or (abs(len(text) - len(t)) < 4 and difflib.SequenceMatcher(None, text.lower(), t.lower()).ratio() > 0.8)
SIG = re.compile(r"Wells.{0,4}Die Zeit|^[\dIlO]{1,2} ?\*?$|^\d \d$")
def regions_from_v3(pages, log):
    """per page: body rectangle (x0, x1, ytop, ybot) from the V3 lines."""
    R = {}
    for p in range(FIRST, LAST + 1):
        L = pages.get(p, [])
        longs = [l for l in L if l['box'][2] > 0.40]
        xl = sorted(l['box'][0] for l in longs)[len(longs) // 5]
        xr = sorted(l['box'][0] + l['box'][2] for l in longs)[len(longs) // 2]
        body = []
        for l in L:
            x, y, w, h = l['box']
            if x < xl - 0.08 and x + w > xl + 0.3:
                log.append((p, 'margin-merged', l['raw']))
                l['text'] = l['text'].split(' ', 1)[1]; l['box'] = (xl, y, x + w - xl, h); l['fused'] = True
            elif x > xr - 0.03 or x + w < xl + 0.03 or x < xl - 0.08:
                log.append((p, 'margin', l['raw'])); continue
            body.append(l)
        body = merge_rows(body)
        # top: page number / chapter head
        firstlong = next(i for i, l in enumerate(body) if l['box'][2] > 0.40)
        if p in CHAPTER_PAGES:
            drop = 0
            while drop < 3 and is_head(body[drop]['raw'], p): drop += 1
            for l in body[:drop]: log.append((p, 'head', l['raw']))
            body = body[drop:]
        else:
            keep = []
            for i, l in enumerate(body):
                if i < firstlong and not (abs(l['box'][0] - xl) < 0.02 and re.search(r"[a-zäöüß]{2}", l['raw'])):
                    log.append((p, 'pagenum', l['raw'])); continue
                keep.append(l)
            body = keep
        while body and SIG.search(body[-1]['raw']) and len(body[-1]['raw']) < 28:
            log.append((p, 'signature', body[-1]['raw'])); body.pop()
        ytop = max(l['box'][1] + l['box'][3] for l in body) + 0.004
        ybot = min(l['box'][1] for l in body) - 0.004
        R[p] = (xl, xr, ytop, ybot)
    return R

def body_lines(pages, R, log=None):
    out = []
    for p in range(FIRST, LAST + 1):
        xl, xr, ytop, ybot = R[p]
        body = []
        for l in pages.get(p, []):
            x, y, w, h = l['box']; cy = y + h / 2
            if x < xl - 0.08 and x + w > xl + 0.3 and ybot < cy < ytop:
                if not l.get('fused'): l['text'] = l['text'].split(' ', 1)[1]; l['box'] = (xl, y, x + w - xl, h); l['fused'] = True
            elif not (ybot < cy < ytop) or x > xr - 0.03 or x + w < xl + 0.03 or x < xl - 0.08:
                if log is not None: log.append((p, 'out', l['raw']))
                continue
            body.append(l)
        body = merge_rows(body)
        mark_indents(body, xl)
        if body:
            body[0]['pagebreak'] = True
            if p in CHAPTER_PAGES: body[0]['chapter'] = True; body[0]['para'] = True
        out += body
    return out

def mark_indents(lines, xl):
    if not lines: return
    xs = sorted(l['box'][0] for l in lines)
    m0 = xs[max(0, len(xs) // 5)]
    inl = [l for l in lines if abs(l['box'][0] - m0) < 0.012]
    a, b = m0, 0.0
    if len(inl) >= 4:
        ys = [l['box'][1] for l in inl]; xx = [l['box'][0] for l in inl]
        my = sum(ys) / len(ys); mx = sum(xx) / len(xx)
        den = sum((y - my) ** 2 for y in ys)
        if den > 1e-6:
            b = sum((y - my) * (x - mx) for x, y in zip(xx, ys)) / den; a = mx - b * my
    for l in lines:
        l['indent'] = l['box'][0] - (a + b * l['box'][1])
        l['para'] = l['indent'] > 0.025

NOUNS_B = set()
def stream(lines):
    toks = []; join = None; kjoins = []
    for li, l in enumerate(lines):
        s = l['text']
        nxt = lines[li + 1]['text'] if li + 1 < len(lines) else ''
        j2 = None
        m = re.search(r"([^\W\d_])[-¬=]$", s)
        if m and not re.search(r"\s[-¬=]$", s):
            nw = re.match(r"[^\W\d_]+", nxt)
            if nw and nw.group(0) in ('und', 'oder', 'bis'): s = s + ' ' + nw.group(0); j2 = 'x'          # "drei- oder viertausend"
            elif nw and nxt[0].islower():
                s = s[:-1]; j2 = 'j'
            elif nw and nxt[0] == 'B' and len(nw.group(0)) > 1 and nw.group(0)[1:].islower() and nw.group(0) not in NOUNS_B:
                s = s[:-1]; j2 = 'ß'                                         # "gro-" / "ßen" read as "Ben"
            elif nw: j2 = 'h'                                                # real hyphen before a capital
        ts = tokenize(s)
        for k, t in enumerate(ts):
            if k == 0 and join == 'x':
                continue                      # the und/oder was already taken with the suspended hyphen
            if join == 'x' and k == len(ts) - 1 and False: pass
            if k == 0 and join and toks and isword(toks[-1]['t']) and isword(t):
                if join == 'ß':
                    toks[-1]['t'] += 'ß' + t[1:]; kjoins.append('ß:' + toks[-1]['t'])
                elif join == 'j':
                    a = toks[-1]['t']
                    if a.endswith('k') and not a.endswith('ck') and t.startswith('k'):
                        a = a[:-1] + 'c'; kjoins.append(a + t)
                    toks[-1]['t'] = a + t
                else: toks[-1]['t'] += t
                continue
            toks.append({'t': t, 'page': l['page'], 'li': li, 'para': bool(l.get('para')) and k == 0, 'brk': l.get('pagebreak', False) and k == 0})
        join = j2
        if j2 == 'h' and toks and not toks[-1]['t'].endswith('-'): toks[-1]['t'] += '-'
    return toks, kjoins

def ref_tokens():
    T = []; chap = -1
    txt = open(os.path.join(D, '..', 'de-ref', 'ref.txt'), encoding='utf-8').read().split('\n')
    for line in txt:
        if line.startswith('=== '):
            chap += 1; head = True; continue
        if chap < 2 or chap > 18 or not line.strip(): continue
        if head: head = False; continue       # chapter title line
        s = norm_text(line.replace('*', '').replace('–', '—'))
        ts = tokenize(s)
        # the reference sets the comma after the closing mark (»Ja«, sagte); the 1904 print before it (»Ja,« sagte): compare in the 1904 order
        for k in range(len(ts) - 1):
            if ts[k] == '«' and ts[k + 1] == ',': ts[k], ts[k + 1] = ',', '«'
        for k, t in enumerate(ts):
            T.append({'t': t, 'para': k == 0})
    return T

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
    anchors = lis(pairs); ops = []; pi = pj = 0
    def sub(i1, i2, j1, j2):
        if i1 == i2 and j1 == j2: return
        sm = difflib.SequenceMatcher(None, a[i1:i2], b[j1:j2], autojunk=False)
        for tag, x1, x2, y1, y2 in sm.get_opcodes(): ops.append((tag, i1 + x1, i1 + x2, j1 + y1, j1 + y2))
    for (i, j) in anchors:
        if i < pi or j < pj: continue
        sub(pi, i, pj, j); ops.append(('equal', i, i + 1, j, j + 1)); pi, pj = i + 1, j + 1
    sub(pi, len(a), pj, len(b))
    return ops

def build():
    log = []
    P = {n: load(n) for n in NAMES}
    R = regions_from_v3(P['v3'], log)
    L3 = body_lines(P['v3'], R)
    streams = []; kj = None
    for n in NAMES:
        lg = [] if n != 'v3' else None
        T, k = stream(body_lines(P[n], R, lg))
        if n == 'v3': kj = k
        streams.append(T)
    streams.append(ref_tokens())
    T3 = streams[0]; k3 = [key(t['t']) for t in T3]
    maps = []
    for T in streams[1:]:
        kx = [key(t['t']) for t in T]; m = [None] * len(k3)
        for tag, i1, i2, j1, j2 in align(k3, kx):
            if tag == 'equal':
                for d in range(i2 - i1): m[i1 + d] = j1 + d
        maps.append(m)
    regions = []; s = 0; prev = [0] * len(maps); n = len(T3)
    for i in range(n + 1):
        stable = i < n and all(m[i] is not None for m in maps)
        if stable or i == n:
            ends = [m[i] if i < n else len(streams[k + 1]) for k, m in enumerate(maps)]
            if i > s or any(e > p for e, p in zip(ends, prev)):
                regions.append(('diff', (s, i), [(p, e) for p, e in zip(prev, ends)]))
            if i < n:
                regions.append(('eq', i, [m[i] for m in maps])); prev = [m[i] + 1 for m in maps]
            s = i + 1
    return L3, streams, regions, log, kj, R

if __name__ == '__main__':
    L3, streams, regions, log, kj, R = build()
    print([len(s) for s in streams], len(regions), sum(r[0] == 'diff' for r in regions))
    pickle.dump((L3, streams, regions, R), open(os.path.join(D, 'merge.pkl'), 'wb'))
    open(os.path.join(D, 'dropped.txt'), 'w', encoding='utf-8').write('\n'.join('%d\t%s\t%s' % x for x in log) + '\n')
    open(os.path.join(D, 'kjoins.txt'), 'w', encoding='utf-8').write('\n'.join(sorted(set(kj))) + '\n')
