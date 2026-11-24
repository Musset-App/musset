# de_zoom.py D out.png page:li:x0:x1 ...  -> enlarged (3x) crops of part of a line (x as fractions of the body width)
import sys, os, pickle
from PIL import Image
D = sys.argv[1]; L3, S, regions, R = pickle.load(open(os.path.join(D, 'merge.pkl'), 'rb'))
out = []
for spec in sys.argv[3:]:
    f = spec.split(':'); pg = int(f[0]); l = L3[int(f[1])]; a = float(f[2]); b = float(f[3])
    im = Image.open(os.path.join(D, 'pages', 'p-%03d.png' % pg)).convert('L'); W, H = im.size
    xl, xr, yt, yb = R[pg]; x0 = xl - 0.02 + a * (xr - xl + 0.055); x1 = xl - 0.02 + b * (xr - xl + 0.055)
    c = im.crop((int(x0 * W), int((1 - l['box'][1] - l['box'][3]) * H) - 14, int(x1 * W), int((1 - l['box'][1]) * H) + 14))
    out.append(c.resize((c.width * 3, c.height * 3), Image.LANCZOS))
M = Image.new('L', (max(c.width for c in out), sum(c.height + 6 for c in out)), 255); y = 0
for c in out: M.paste(c, (0, y)); y += c.height + 6
M.save(sys.argv[2]); print(M.size)
