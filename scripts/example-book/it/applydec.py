import json, sys, os
D = sys.argv[1]
R = json.load(open(os.path.join(D, 'review.json'), encoding='utf-8'))
dec = {}
for fn in sorted(os.listdir(D)):
    if fn.startswith('dec') and fn.endswith('.txt'):
        for line in open(os.path.join(D, fn), encoding='utf-8'):
            line = line.rstrip('\n')
            if not line or line.startswith('#'): continue
            k, _, v = line.partition(' ')
            dec[k] = v
out = {}; pend = []; bad = []
old = os.path.join(D, 'decisions.json')
if os.path.exists(old): out = json.load(open(old, encoding='utf-8'))
ids = set(r['id'] for r in R)
for k in dec:
    if k not in ids and k not in out: bad.append(k)
for r in R:
    v = dec.get(r['id'])
    if v is None:
        if r['V1'] == r['V3']: v = 'V1'
        else: bad.append(r['id'] + ' V1!=V3'); continue
    if v == '?': pend.append(r); continue
    out[r['id']] = v
if '--write' in sys.argv:
    json.dump(out, open(old, 'w', encoding='utf-8'), ensure_ascii=False, indent=0)
print('decided', len(out), 'pending', len(pend), 'bad', bad)
json.dump(pend, open(os.path.join(D, 'pending.json'), 'w', encoding='utf-8'), ensure_ascii=False)
