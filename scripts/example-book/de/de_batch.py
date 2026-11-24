# de_batch.py D name ids.txt  -> crops/name-N.png (40 strips each) and prints the items; ids.txt: one id per line (from review.json / refdiff.json)
import json, sys, os, subprocess
D = sys.argv[1]; name = sys.argv[2]
ids = [l.split()[0] for l in open(sys.argv[3]) if l.strip()]
items = {r['id']: r for fn in ('review.json', 'refdiff.json') for r in json.load(open(os.path.join(D, fn), encoding='utf-8'))}
here = os.path.dirname(os.path.abspath(__file__)); N = int(sys.argv[4]) if len(sys.argv) > 4 else 40
ids = [i for i in ids if i in items]
for b in range(0, len(ids), N):
    chunk = ids[b:b + N]
    specs = ['%d:%d:%s' % (items[i]['page'], items[i]['li'], '%d' % (b + k + 1)) for k, i in enumerate(chunk)]
    subprocess.run([sys.executable, '-P', os.path.join(here, 'de_crops.py'), D, os.path.join(D, 'crops', '%s-%d.png' % (name, b // N + 1))] + specs)
    for k, i in enumerate(chunk):
        r = items[i]; o = r['o']
        v = o[0] if len(set(o)) == 1 else ' | '.join(o)
        print(b + k + 1, i, 'p%d' % r['page'], '…' + r['l'][-18:], '[', v, '→REF:', r['ref'], ']', r['r'][:12])
