# estimates slant of each word box (italic detection). usage: slant.py D firstpage lastpage -> slant.tsv
import sys, os, numpy as np
from PIL import Image
D = sys.argv[1]; P0 = int(sys.argv[2]); P1 = int(sys.argv[3])
def best_shear(a):
    # a: 2D array, ink=1. returns shear (dx per dy) maximising vertical-projection sharpness
    h, w = a.shape
    best = (0, -1)
    res = {}
    for k in np.arange(-0.15, 0.46, 0.05):
        acc = np.zeros(w + h)
        for y in range(h):
            off = int(round((h - 1 - y) * k)) if k >= 0 else int(round(-y * k))
            off = int(round((y) * k + (h if k < 0 else 0) * abs(k)))
            acc[off:off + w] += a[y]
        v = float((np.diff(acc) ** 2).sum())
        res[round(float(k), 2)] = v
        if v > best[1]: best = (round(float(k), 2), v)
    return best[0], res
out = open(os.path.join(D, 'slant.tsv'), 'w', encoding='utf-8')
page = None; im = None
for raw in open(os.path.join(D, 'vision3.tsv'), encoding='utf-8'):
    raw = raw.rstrip('\n')
    if raw.startswith('=== page'):
        page = int(raw.split()[-1]); im = None
        if P0 <= page <= P1:
            im = np.asarray(Image.open(os.path.join(D, 'pages', 'p-%03d.png' % page)).convert('L').resize((1396, 2234), Image.LANCZOS), dtype=float)
        continue
    if im is None: continue
    f = raw.split('\t', 5)
    if f[0] not in 'LW': continue
    x, y, w, h = map(float, f[1:5]); H, W = im.shape
    x0 = max(0, int(x * W) - 2); x1 = min(W, int((x + w) * W) + 2); y0 = max(0, int((1 - y - h) * H)); y1 = min(H, int((1 - y) * H))
    if x1 - x0 < 8 or y1 - y0 < 8: continue
    c = im[y0:y1, x0:x1]
    thr = (c.min() + np.median(c)) / 2
    a = (c < thr).astype(float)
    k, res = best_shear(a)
    out.write('%s\t%d\t%.4f\t%.4f\t%.2f\t%s\n' % (f[0], page, x, y, k, f[5]))
