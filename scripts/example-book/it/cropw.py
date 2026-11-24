# cropw.py D out.png page:word[:n] ...  -> crops of the line(s) holding that token on that page (n = which occurrence, default all)
import json, subprocess, sys, os
D = sys.argv[1]; out = sys.argv[2]
T = json.load(open(os.path.join(D, 'resolved.json'), encoding='utf-8'))
here = os.path.dirname(os.path.abspath(__file__))
specs = []
for a in sys.argv[3:]:
    f = a.split(':'); pg = int(f[0]); w = f[1]
    lis = []
    for t in T:
        if t['page'] == pg and t['t'] == w and t['li'] not in lis: lis.append(t['li'])
    if len(f) > 2: lis = lis[int(f[2]):int(f[2])+1]
    if not lis: print('NOT FOUND', a)
    for li in lis: specs.append('%d:%d:%d %s' % (pg, li, pg, w[:9]))
subprocess.run([sys.executable, '-P', os.path.join(here, 'crops.py'), D, out] + specs)
