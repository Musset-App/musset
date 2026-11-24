# resolved.json -> lines.txt: one printed line per line, "pNNN LNN ¶|· text" (¶ = indented line).
import json, sys, os
D = sys.argv[1]
toks = json.load(open(os.path.join(D, 'resolved.json'), encoding='utf-8'))
def join(ts):
    out = ''; prev = None
    for t in ts:
        s = t['t']
        if s.startswith('~'): s = s[1:]; t = dict(t, sp=False)
        if prev is None: out = s; prev = s; continue
        sp = True
        if s[0] in ',.;:!?)»…': sp = False
        if prev[-1] in '¿¡(«': sp = False
        if s == '—': sp = t.get('sp', True) and prev[-1] in '.!?…'
        if prev == '—': sp = False
        out += (' ' if sp else '') + s; prev = s
    return out
lines = []   # [page, para, chapter, [tokens]]
for t in toks:
    if t['t'].startswith('~'): t['t'] = t['t'][1:]; t['sp'] = False
    if t.get('first') or not lines: lines.append([t['page'], bool(t.get('para')), t.get('chapter'), []])
    if 'brk' in t and 0 < t['brk'] < len(t['t']):
        a, b = t['t'][:t['brk']], t['t'][t['brk']:]
        lines[-1][3].append(dict(t, t=a + '-'))
        lines.append([t['next']['page'], False, None, [dict(t, t=b, sp=True)]])
    else: lines[-1][3].append(t)
out = []; n = {}
for page, para, ch, ts in lines:
    n[page] = n.get(page, 0) + 1
    out.append('p%03d L%02d %s %s' % (page, n[page], '#' if ch else '¶' if para else '·', join(ts)))
open(os.path.join(D, 'lines.txt'), 'w', encoding='utf-8').write('\n'.join(out) + '\n')
print(len(out), 'lines', len(n), 'pages')
