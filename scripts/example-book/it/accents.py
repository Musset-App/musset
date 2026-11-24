# lists words in the draft whose final-accented variant is a valid Italian word
import re, subprocess, collections, sys, os, json
D = sys.argv[1]
here = os.path.dirname(os.path.abspath(__file__))
t = open(os.path.join(D, 'example-time-machine-it.md'), encoding='utf-8').read()
ACC = {'a': 'à', 'e': 'è', 'i': 'ì', 'o': 'ò', 'u': 'ù'}
words = collections.Counter(re.findall(r"[^\W\d_]+", t))
cand = {}
for w in words:
    if w[-1] in ACC and len(w) > 1: cand[w] = w[:-1] + ACC[w[-1]]
q = set()
for w, v in cand.items():
    for x in (w, w.lower(), v, v.lower(), v.replace('è', 'é'), v.lower().replace('è', 'é')): q.add(x)
ok = set(subprocess.run([os.path.join(here, 'spell')], input='\n'.join(sorted(q)), capture_output=True, text=True).stdout.split('\n'))
auto = {}; amb = {}
SKIP = {'e', 'la', 'ne', 'si', 'li', 'di', 'da', 'se', 'te', 'che', 'sta', 'fa', 'va', 'do', 'sto', 'so', 'fu', 'me', 'tre', 'su', 'qui', 'qua', 'no', 'ma', 'gia'}
for w, v in cand.items():
    vok = v in ok or v.lower() in ok or v.replace('è', 'é') in ok or v.lower().replace('è', 'é') in ok
    wok = w in ok or w.lower() in ok
    if not vok or w.lower() in SKIP: continue
    if not wok: auto[w] = v
    else: amb[w] = v
print('AUTO', ' '.join('%s:%d' % (w, words[w]) for w in sorted(auto)))
print('AMB', len(amb), sum(words[w] for w in amb))
print(' '.join('%s:%d' % (w, words[w]) for w in sorted(amb)))
json.dump({'auto': auto, 'amb': amb}, open(os.path.join(D, 'accents.json'), 'w', encoding='utf-8'), ensure_ascii=False)
