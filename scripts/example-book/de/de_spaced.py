# finds spaced-out (gesperrt) text by measuring, on the page image, the blank gaps between letters inside each word box
import sys, os, re
import numpy as np
from PIL import Image
D = sys.argv[1]; p = None; im = None
out = open(os.path.join(D, 'spaced.tsv'), 'w', encoding='utf-8')
line = None
def flush():
    if line and any(x[1] for x in line[1]):
        out.write('%d\t%s\t%s\n' % (line[2], line[0], ' '.join(('[%s]' % t if s else t) for t, s in line[1])))
for raw in open(os.path.join(D, 'v3.tsv'), encoding='utf-8'):
    raw = raw.rstrip('\n')
    if raw.startswith('==='):
        flush(); line = None
        p = int(raw.split()[-1]); im = None
        if 10 <= p <= 184: im = np.asarray(Image.open(os.path.join(D, 'pages', 'p-%03d.png' % p)).convert('L'), dtype=float)
        continue
    if im is None: continue
    f = raw.split('\t', 5)
    if f[0] == 'L':
        flush(); line = [f[5], [], p]; continue
    x, y, w, h = map(float, f[1:5]); H, W = im.shape; t = f[5]
    n = len(re.sub(r'[^\w]', '', t))
    x0 = int(x * W); x1 = int((x + w) * W); y0 = int((1 - y - h) * H); y1 = int((1 - y) * H)
    c = im[y0:y1, x0:x1]
    sp = False
    if n >= 2 and c.size:
        thr = (c.min() + np.median(c)) / 2
        ink = (c < thr).sum(axis=0) > 0
        runs = []; k = 0
        for v in ink:
            if not v: k += 1
            else:
                if k: runs.append(k)
                k = 0
        if len(ink) and not ink[0] and runs: runs = runs[1:]      # blank before the first letter
        big = sum(1 for r in runs if r >= 8)
        sp = big >= max(1, round(0.7 * (n - 1)))
    line[1].append((t, sp))
flush()
