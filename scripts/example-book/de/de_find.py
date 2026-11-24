# de_find.py D out.png "page:substring[:nlines]" ...  -> line strips of the V3 lines on that page containing the substring
import sys, os, pickle, subprocess
D = sys.argv[1]; L3 = pickle.load(open(os.path.join(D, 'merge.pkl'), 'rb'))[0]
specs = []
for a in sys.argv[3:]:
    f = a.split(':'); pg = int(f[0]); n = f[2] if len(f) > 2 else '1'
    hit = [i for i, l in enumerate(L3) if l['page'] == pg and f[1] in l['text']]
    if not hit: print('NOT FOUND', a)
    for i in hit[:2]: specs.append('%d:%d:%d:%s' % (pg, i, pg, n))
subprocess.run([sys.executable, '-P', os.path.join(os.path.dirname(os.path.abspath(__file__)), 'de_crops.py'), D, sys.argv[2]] + specs)
