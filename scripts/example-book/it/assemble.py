# Builds the Markdown from resolved.json, applies postedits.txt, writes draft.md with page markers and the final file.
import json, sys, os, re, pickle, collections
D = sys.argv[1]
toks = json.load(open(os.path.join(D, 'resolved.json'), encoding='utf-8'))
L3 = pickle.load(open(os.path.join(D, 'merge.pkl'), 'rb'))[0]
TITLES = ['Introduzione', 'La macchina', 'L’Esploratore ritorna', 'Il viaggio', 'Nell’età dell’oro', 'Il crepuscolo dell’umanità',
          'Un colpo inaspettato', 'Esplorazioni', 'I Morlocks', 'Quando venne la notte', 'Il palazzo di porcellana verde',
          'Nelle tenebre', 'La trappola della sfinge bianca', 'L’ultima visione', 'Il ritorno dell’Esploratore', 'Dopo il racconto', 'Epilogo']
CHAPTER_PAGES = [7, 17, 25, 37, 48, 57, 69, 81, 101, 112, 125, 138, 151, 157, 167, 170, 178]
TRUNC = {'po’', 'pe’', 'de’', 'a’', 'co’', 'ne’', 'que’', 'be’', 'mo’', 'vo’', 'e’', 'su’', 'da’', 'di’', 'fe’', 'i’', 'to’', 'se’'}
NOSPACE_BEFORE = set(',.;:!?)»')
NOSPACE_AFTER = set('(«')

def render(t):
    if t.startswith('…'):
        n = int(t[1:]) if t[1:].isdigit() else 3
        return '…' + '.' * max(0, n - 3)
    return t

paras = []   # list of (kind, text, page)
cur = []; curpage = None
seen_ch = set()
pcheck = []
dropped = []
def flush():
    global cur
    if cur: paras.append(('p', cur, curpage))
    cur = []
for i, t in enumerate(toks):
    pg = t['page']
    if pg in CHAPTER_PAGES and pg not in seen_ch:
        seen_ch.add(pg); flush()
        paras.append(('h', TITLES[CHAPTER_PAGES.index(pg)], pg))
        t['para'] = True
    prevt = toks[i-1]['t'] if i else None
    endok = prevt is None or prevt in '.!?»:—' or prevt.startswith('…')
    if t.get('apara') == 'y' and not t.get('para') and prevt in ('.', '!', '?') and t['t'][:1].isupper():
        t['para'] = True; dropped.append(('ADDED from A', pg, ' '.join(x['t'] for x in toks[max(0, i-4):i]) + ' ¶ ' + ' '.join(x['t'] for x in toks[i:i+5])))
    if t.get('para') and not endok and not (pg in CHAPTER_PAGES and paras and paras[-1][0] == 'h' and not cur):
        t['para'] = False; dropped.append(('DROPPED', pg, ' '.join(x['t'] for x in toks[max(0, i-4):i]) + ' ¶ ' + ' '.join(x['t'] for x in toks[i:i+5])))
    if t.get('para'):
        flush(); curpage = pg
    ap = t.get('apara')
    if ap in ('y', 'n') and (ap == 'y') != bool(t.get('para')):
        pcheck.append((pg, t['li'], 'A=para V=no' if ap == 'y' else 'V=para A=no', ' '.join(x['t'] for x in toks[max(0, i-4):i]) + ' ¶ ' + ' '.join(x['t'] for x in toks[i:i+5])))
    cur.append(t)
flush()

def join(ts):
    out = ''
    prev = None
    for t in ts:
        s = render(t['t'])
        if prev is None: out = s
        else:
            p = prev
            sp = True
            if s[0] in NOSPACE_BEFORE: sp = False
            if s.startswith('…') and p not in ('—', '«', '('): sp = False
            if p[-1] in NOSPACE_AFTER: sp = False
            if p.endswith('’') and p not in TRUNC and p.lower() not in TRUNC: sp = False
            out += (' ' if sp else '') + s
        prev = s
    return out

blocks = []; dbg = []
for kind, x, pg in paras:
    if kind == 'h':
        blocks.append('# ' + x); dbg.append('# ' + x)
    else:
        s = join(x); blocks.append(s); dbg.append('[p%d] ' % pg + s)
text = '\n\n'.join(blocks) + '\n'
# post-edits: lines "old => new" (exact, must match expected count; default 1; prefix "N× " for count)
bad = []
# global spelling of the print: "cosi" for "così" is a missing accent (the book prints "così" 20+ times)
text = re.sub(r'\bcosi\b', 'così', text); text = re.sub(r'\bCosi\b', 'Così', text)
for fn in ('postedits.txt', 'printfixes.txt'):
    pe = os.path.join(D, fn)
    if not os.path.exists(pe): continue
    for line in open(pe, encoding='utf-8'):
        line = line.rstrip('\n')
        if not line or line.startswith('#'): continue
        n = 1
        m = re.match(r'(\d+)× ', line)
        if m: n = int(m.group(1)); line = line[m.end():]
        old, new = line.split(' => ')
        old = old.replace('\\n', '\n'); new = new.replace('\\n', '\n')
        if old == new: continue
        c = text.count(old)
        if c != n: bad.append((fn, old, c)); continue
        text = text.replace(old, new)
open(os.path.join(D, 'draft_pages.txt'), 'w', encoding='utf-8').write('\n\n'.join(dbg) + '\n')
open(os.path.join(D, 'example-time-machine-it.md'), 'w', encoding='utf-8').write(text)
open(os.path.join(D, 'paracheck.txt'), 'w', encoding='utf-8').write('\n'.join('%d %d %s | %s' % p for p in pcheck) + '\n')
for d in dropped: print(*d)
print('paragraphs', len(blocks), 'words', len(re.findall(r"[^\W_]+(?:’[^\W_]+)*", text)), 'paracheck', len(pcheck), 'bad postedits', bad)
ap = collections.Counter(t['t'] for t in toks if t['t'].endswith('’'))
print('apostrophe tokens:', ' '.join('%s:%d' % kv for kv in ap.most_common()))
odd = collections.Counter(t['t'] for t in toks if not re.match(r"[^\W_]", t['t']) and t['t'] not in ',.;:!?—()«»' and not t['t'].startswith('…'))
print('odd tokens:', odd)
print('ellipses:', collections.Counter(t['t'] for t in toks if t['t'].startswith('…')))
