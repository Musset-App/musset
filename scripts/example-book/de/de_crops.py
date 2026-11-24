# montage of line strips: de_crops.py D out.png page:li:label[:nlines] ...   (two columns)
import sys, os, pickle
from PIL import Image, ImageDraw, ImageFont
D = sys.argv[1]; outp = sys.argv[2]
L3, S, regions, R = pickle.load(open(os.path.join(D, 'merge.pkl'), 'rb'))
font = ImageFont.load_default(size=22)
cache = {}; strips = []
for spec in sys.argv[3:]:
    f = spec.split(':'); pg = int(f[0]); li = int(f[1]); label = f[2] if len(f) > 2 else ''; n = int(f[3]) if len(f) > 3 else 1
    if pg not in cache: cache.clear(); cache[pg] = Image.open(os.path.join(D, 'pages', 'p-%03d.png' % pg)).convert('L')
    im = cache[pg]; W, H = im.size
    xl, xr, yt, yb = R[pg]
    ls = [l for l in L3[li:li + n] if l['page'] == pg] or [L3[li]]
    top = min(int((1 - l['box'][1] - l['box'][3]) * H) for l in ls) - 9; bot = max(int((1 - l['box'][1]) * H) for l in ls) + 9
    c = im.crop((int((xl - 0.02) * W), max(0, top), int((xr + 0.035) * W), min(H, bot)))
    strips.append((label, c))
cw = max(c.width for _, c in strips) + 110
half = (len(strips) + 1) // 2
cols = [strips[:half], strips[half:]]
Ht = max(sum(c.height + 3 for _, c in col) for col in cols)
M = Image.new('L', (cw * 2, Ht), 255); d = ImageDraw.Draw(M)
for k, col in enumerate(cols):
    yy = 0
    for label, c in col:
        d.text((k * cw + 2, yy + c.height // 2 - 11), label, fill=0, font=font)
        M.paste(c, (k * cw + 110, yy)); yy += c.height + 3
M.save(outp); print(outp, M.size)
