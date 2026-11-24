# montage of line crops: crops.py D out.png page:li[:label] ...
import sys, os, pickle
from PIL import Image, ImageDraw, ImageFont
D = sys.argv[1]; outp = sys.argv[2]
L3 = pickle.load(open(os.path.join(D, 'merge.pkl'), 'rb'))[0]
strips = []
font = ImageFont.load_default(size=20)
cache = {}
for spec in sys.argv[3:]:
    f = spec.split(':'); li = int(f[1]); label = f[2] if len(f) > 2 else ''
    l = L3[li]; pg = l['page']
    if pg not in cache: cache[pg] = Image.open(os.path.join(D, 'pages', 'p-%03d.png' % pg)).convert('L')
    im = cache[pg]; W, H = im.size
    x, y, w, h = l['box']
    top = int((1 - y - h) * H) - 7; bot = int((1 - y) * H) + 7
    c = im.crop((0, max(0, top), W, min(H, bot)))
    c = c.resize((int(c.width * 2.2), int(c.height * 2.2)), Image.LANCZOS)
    strips.append((label, c))
Wd = max(c.width for _, c in strips) + 150
Ht = sum(c.height + 4 for _, c in strips)
M = Image.new('L', (Wd, Ht), 255); d = ImageDraw.Draw(M); yy = 0
for label, c in strips:
    d.text((4, yy + c.height // 2 - 10), label, fill=0, font=font)
    M.paste(c, (150, yy)); yy += c.height + 4
M.save(outp)
print(M.size)
