# Builds the Markdown from resolved.json; applies postedits.txt (OCR/assembly repairs, emphasis) and printfixes.txt (misprints of the 1904 print).
import json, sys, os, re, collections
D = sys.argv[1]
toks = json.load(open(os.path.join(D, 'resolved.json'), encoding='utf-8'))
TITLES = ['Einführung', 'Die Maschine', 'Der Zeitreisende kehrt zurück', 'Das Reisen in der Zeit', 'In der goldenen Zeit', 'Der Sonnenuntergang der Menschheit',
          'Ein plötzlicher Schlag', 'Erklärung', 'Die Morlocken', 'Als die Nacht kam', 'Der grüne Porzellanpalast', 'Im Dunkel', 'Die Falle in der weißen Sphinx',
          'Die weitere Vision', 'Die Rückkehr des Zeitreisenden', 'Nach der Erzählung', 'Epilog']
CHAPTER_PAGES = [10, 21, 29, 40, 51, 60, 72, 84, 106, 117, 130, 143, 156, 162, 172, 175, 183]
ELISION = {'Heut’', 'heut’'}
NOSPACE_BEFORE = set(',.;:!?)«‘“')
NOSPACE_AFTER = set('(»‚„')
for t in toks:
    if t['t'] == '’': t['t'] = '‘'
    elif t['t'].endswith('’') and t['t'] not in ELISION: t['t'] = t['t'][:-1] + '‘'

# a paragraph cannot begin with a closing mark: where a decision region carried the break, pass it on to the first opening token
for i, t in enumerate(toks[:-1]):
    if t.get('para') and t['t'] in ('«', '.', ',', '‘', '?', '!', ';', ':'):
        t['para'] = False; toks[i + 1]['para'] = True
        if t.get('rpara'): t['rpara'] = False; toks[i + 1]['rpara'] = True
# the » that opens a chapter belongs to the chapter page, also when its region began on the page before
for i, t in enumerate(toks[:-1]):
    if t['t'] == '»' and toks[i + 1]['page'] in CHAPTER_PAGES and t['page'] != toks[i + 1]['page']: t['page'] = toks[i + 1]['page']
paras = []; cur = []; curpage = None; seen = set(); pcheck = []
def flush():
    global cur
    if cur: paras.append(('p', cur, curpage))
    cur = []
for i, t in enumerate(toks):
    pg = t['page']
    if pg in CHAPTER_PAGES and pg not in seen:
        seen.add(pg); flush(); paras.append(('h', TITLES[CHAPTER_PAGES.index(pg)], pg)); t['para'] = True
    if bool(t.get('para')) != bool(t.get('rpara')) and t['src'] in ('agree',) and cur:
        pcheck.append((pg, t['li'], 'scan=para ref=no' if t.get('para') else 'ref=para scan=no', ' '.join(x['t'] for x in toks[max(0, i - 5):i]) + ' ¶ ' + ' '.join(x['t'] for x in toks[i:i + 5])))
    if t.get('para'): flush(); curpage = pg
    cur.append(t)
flush()

def render(t):
    if t.startswith('…') and t[1:].isdigit(): return '…'
    return t
def join(ts):
    out = ''; prev = None
    for t in ts:
        raw = t['t']; s = render(raw)
        if prev is None: out = s
        else:
            sp = True
            if s[0] in NOSPACE_BEFORE or s.startswith('[^'): sp = False
            if prev[-1] in NOSPACE_AFTER: sp = False
            if raw == '…4': out += '.'; sp = True          # ". . . ." = full stop and three dots
            out += (' ' if sp else '') + s
        prev = s
    return out
blocks = []; dbg = []
for kind, x, pg in paras:
    if kind == 'h': blocks.append('# ' + x); dbg.append('# ' + x)
    else:
        s = join(x); blocks.append(s); dbg.append('[p%d] ' % pg + s)
text = '\n\n'.join(blocks) + '\n'
bad = []
def apply(text, fn):
    pe = os.path.join(D, fn)
    if not os.path.exists(pe): return text
    for line in open(pe, encoding='utf-8'):
        line = line.rstrip('\n')
        if not line or line.startswith('#'): continue
        n = 1
        m = re.match(r'(\d+)× ', line)
        if m: n = int(m.group(1)); line = line[m.end():]
        old, new = line.split(' => ')
        old = old.replace('\\n', '\n'); new = new.replace('\\n', '\n')
        c = text.count(old)
        if c != n: bad.append((fn, old, c)); continue
        text = text.replace(old, new)
    return text
text = apply(text, 'postedits.txt')
# the one footnote of the print (p135, marked *) in the scan), as a Markdown footnote after its paragraph
FOOT = '[^1]: Natürlich ist es möglich, daß sich der Boden auch nicht senkte, sondern daß das Gebäude auf einem Hügelhang gebaut war.'
bl = text.rstrip('\n').split('\n\n')
k = [i for i, b in enumerate(bl) if '[^1]' in b]
assert len(k) == 1
bl.insert(k[0] + 1, FOOT); text = '\n\n'.join(bl) + '\n'
open(os.path.join(D, 'asprinted.md'), 'w', encoding='utf-8').write(text)       # the print, misprints included
text = apply(text, 'printfixes.txt')
open(os.path.join(D, 'draft_pages.txt'), 'w', encoding='utf-8').write('\n\n'.join(dbg) + '\n')
open(os.path.join(D, 'example-time-machine-de.md'), 'w', encoding='utf-8').write(text)
open(os.path.join(D, 'paracheck.txt'), 'w', encoding='utf-8').write('\n'.join('%d %d %s | %s' % p for p in pcheck) + '\n')
print('blocks', len(blocks), 'words', len(re.findall(r"[^\W_]+(?:[’-][^\W_]+)*", re.sub(r'^# .*$', '', text, flags=re.M))), 'paracheck', len(pcheck), 'bad', bad)
odd = collections.Counter(t['t'] for t in toks if not re.match(r"[^\W_]", t['t']) and t['t'] not in ',.;:!?—()«»‚‘' and not t['t'].startswith('…'))
print('odd tokens:', odd, collections.Counter(t['t'] for t in toks if t['t'].startswith('…')))
# quotation balance per paragraph
for b, d in zip(text.split('\n\n'), dbg):
    o, c = b.count('»'), b.count('«'); io, ic = b.count('‚'), b.count('‘')
    if abs(o - c) > 1 or o < c or io != ic: print('QUOTES', d[:8], o, c, io, ic, '|', b[:60], '…', b[-40:])
