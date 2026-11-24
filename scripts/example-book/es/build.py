# lines.txt + the corrections read on the page images -> the Markdown of the Spanish example book.
#   build.py <dir> <out.md>
# Corrections (corr-*.txt), one per line:
#   p048 L02 · corrected line        replace
#   p051 L07+ · a missing line       insert after L07
#   p060 L12 DELETE
#   p115 L29 F footnote text         the line belongs to a footnote
# Then printfixes.txt: "printed => corrected", the printer's evident misprints.
import sys, os, re, glob, collections
D, OUT = sys.argv[1], sys.argv[2]
TITLES = ['Introducción', 'La Máquina', 'La vuelta del Explorador del Tiempo', 'La Exploración del Tiempo', 'En la Edad de Oro',
          'El Ocaso de la Humanidad', 'Un accidente inesperado', 'Exploraciones', 'Los Morlocks', 'Al llegar la noche',
          'El Palacio de Porcelana Verde', 'En las tinieblas', 'La trampa de la Blanca Esfinge', 'La última visión',
          'El regreso del Explorador del Tiempo', 'Después de la historia', 'Epílogo']
LINE = re.compile(r'(p\d{3}) L(\d{2})(\+*) (DELETE|[·¶#F])(?: (.*))?$')
lines = collections.OrderedDict()   # (page, n, sub) -> [mark, text]
for raw in open(os.path.join(D, 'lines.txt'), encoding='utf-8'):
    m = LINE.match(raw.rstrip('\n'))
    if m: lines[(m.group(1), int(m.group(2)), 0)] = [m.group(4), m.group(5) or '']
ncorr = 0; bad = []
for fn in sorted(glob.glob(os.path.join(D, 'corr-*.txt'))):
    for raw in open(fn, encoding='utf-8'):
        raw = raw.rstrip('\n')
        if not raw.strip() or raw.startswith(('MISPRINT', 'UNSURE', '#')): continue
        m = LINE.match(raw)
        if not m: bad.append((os.path.basename(fn), raw)); continue
        k = (m.group(1), int(m.group(2)), len(m.group(3)))
        if m.group(4) == 'DELETE':
            if k in lines: del lines[k]; ncorr += 1
            else: bad.append((os.path.basename(fn), raw))
        elif k[2] == 0 and k not in lines: bad.append((os.path.basename(fn), raw))
        else: lines[k] = [m.group(4), m.group(5) or '']; ncorr += 1
order = sorted(lines)
blocks = []; cur = None; notes = []; note = None; nch = 0; odd = []
def glue(a, b):
    if re.search(r'[^\W\d_]-$', a) and b[:1].islower(): return a[:-1] + b
    if re.search(r'[^\W\d_]-\*$', a) and b[:2] == '*' + b[1:2] and b[1:2].islower(): return a[:-2] + b[1:]
    return a + ' ' + b
for k in order:
    mark, text = lines[k]
    text = text.strip()
    if not text: continue
    if mark == 'F':
        note = text if note is None else glue(note, text); continue
    if mark == '#':
        if cur: blocks.append(cur)
        blocks.append('# ' + TITLES[nch]); nch += 1; cur = text; continue
    if mark == '¶':
        if cur:
            if not re.search(r'[.!?»:…*)]$|—$', cur) and not text.startswith('—'): odd.append('%s L%02d ¶ after «…%s»' % (k[0], k[1], cur[-40:]))
            blocks.append(cur)
        cur = text
    else: cur = text if cur is None else glue(cur, text)
if cur: blocks.append(cur)
text = '\n\n'.join(blocks) + '\n'
if note:
    m = re.match(r'\((\d)\) ?', note); note = note[m.end():] if m else note
    paras = text.split('\n\n')
    i = next(i for i, p in enumerate(paras) if '(1)' in p)
    paras[i] = paras[i].replace(' (1)', '[^1]').replace('(1)', '[^1]')
    paras.insert(i + 1, '[^1]: ' + note)
    text = '\n\n'.join(paras)
text = re.sub(r'\.\.\.+', '…', text)
text = text.replace('* *', ' ')   # an italic passage that ran over a line end
text = text.replace(' ', ' ')
text = re.sub(r'  +', ' ', text)
misses = []
pf = os.path.join(D, 'printfixes.txt')
if os.path.exists(pf):
    for line in open(pf, encoding='utf-8'):
        line = line.rstrip('\n')
        if not line or line.startswith('#'): continue
        n = 1
        m = re.match(r'(\d+)× ', line)
        if m: n = int(m.group(1)); line = line[m.end():]
        old, new = line.split(' => ')
        old = old.replace('\\n', '\n'); new = new.replace('\\n', '\n')
        if text.count(old) != n: misses.append((old, text.count(old))); continue
        text = text.replace(old, new)
open(OUT, 'w', encoding='utf-8').write(text)
open(os.path.join(D, 'odd-paragraphs.txt'), 'w', encoding='utf-8').write('\n'.join(odd) + '\n')
print('corrections', ncorr, 'unplaced', len(bad), 'blocks', len(text.split('\n\n')), 'headings', nch,
      'words', len(re.findall(r"[^\W_]+", text)), 'odd ¶', len(odd), 'printfix misses', misses)
for b in bad[:30]: print('UNPLACED', *b)
