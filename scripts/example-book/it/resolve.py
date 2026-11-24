# Applies resolution rules to the aligned regions; writes resolved.json (tokens) and review.json (open questions).
import pickle, sys, os, json, re, collections, hashlib, unicodedata
D = sys.argv[1]
L3, T3, T1, TA, regions = pickle.load(open(os.path.join(D, 'merge.pkl'), 'rb'))
DEC = {}
p = os.path.join(D, 'decisions.json')
if os.path.exists(p): DEC = json.load(open(p, encoding='utf-8'))

ACUTE = str.maketrans('áéíóúÁÉÍÓÚ', 'àèìòùÀÈÌÒÙ')
def g(t): return t.translate(ACUTE)
def deaccent(s): return ''.join(c for c in unicodedata.normalize('NFD', s) if unicodedata.category(c) != 'Mn')
def isword(t): return bool(re.match(r"[^\W_]", t))
def final_accent_only(a, v):
    """a differs from v only by a grave accent on the last vowel letter of a."""
    if len(a) != len(v) or deaccent(a) != deaccent(v): return False
    core_a, core_v = a.rstrip('’'), v.rstrip('’')
    return core_a[:-1] == core_v[:-1] and core_a[-1] in 'àèìòù' and core_v[-1] in 'aeiou'

for T in (T3, T1, TA):
    for t in T: t['t'] = g(t['t'])

# lexicon from full agreement
lex = collections.Counter()
for r in regions:
    if r[0] == 'eq':
        a, b, c = TA[r[2]]['t'], T1[r[3]]['t'], T3[r[1]]['t']
        if a == b == c and isword(a): lex[a] += 1
SPELL = set(open(os.path.join(D, 'spellok.txt'), encoding='utf-8').read().split('\n'))
def valid(t):
    if not isword(t) or t.isdigit(): return True
    if lex[t] or lex[t.lower()]: return True
    if t.endswith('’'): return False
    if len(t) < 4: return False
    v = t.replace('è', 'é')
    return t in SPELL or t.lower() in SPELL or v in SPELL or v.lower() in SPELL
def inlex(toks, n=1):
    return all(valid(t) for t in toks)

def L_A_unknown(ai): return bool(TA[ai].get('unk'))
out = []      # dict(t, page, li, para, src)
review = []
stats = collections.Counter()
internal_log = []
def rid(page, a, b, c, ctx):
    return hashlib.md5(('%s|%s|%s|%s|%s' % (page, a, b, c, ctx)).encode()).hexdigest()[:7]

def emit(toks, ref, src, first_para=None):
    for k, t in enumerate(toks):
        out.append({'t': t, 'page': ref['page'], 'li': ref['li'], 'para': (first_para if k == 0 else False), 'brk': ref.get('brk', False) and k == 0, 'src': src})

pending_para = False
pending_brk = False
items = []
for r in regions:
    if r[0] == 'eq':
        items.append(([TA[r[2]]['t']], [T1[r[3]]['t']], [T3[r[1]]['t']], r[1], r[1]+1, r[2]))
    else:
        (s, e), (a1, a2), (b1, b2) = r[1:]
        A = [t['t'] for t in TA[a1:a2]]; B = [t['t'] for t in T1[b1:b2]]; C = [t['t'] for t in T3[s:e]]
        if len(A) == len(B) == len(C) > 1 and not any('splor' in x.lower() for x in A + C):
            for k in range(len(A)): items.append(([A[k]], [B[k]], [C[k]], s+k, s+k+1, None))
        else:
            items.append((A, B, C, s, e, None))
for A, B, C, s, e, ai in items:
    ref = T3[s] if s < len(T3) and s < e else (T3[s-1] if s > 0 else T3[0])
    para = any(T3[i]['para'] for i in range(s, e)) or pending_para
    brk = any(T3[i].get('brk') for i in range(s, e))
    pending_para = False
    ja, jb, jc = ' '.join(A), ' '.join(B), ' '.join(C)
    choice = None; why = None
    if ja == jb == jc: choice, why = A, 'agree'
    elif ja == jb or ja == jc: choice, why = A, 'A+V'
    else:
        na, nb, nc = ja.replace(' ', ''), jb.replace(' ', ''), jc.replace(' ', '')
        if len(A) == 1 and len(C) == 1 and len(B) == 1 and isword(A[0]) and jb.lower() != ja.lower():
            # accent rules, single word
            if final_accent_only(ja, jc) and (jb == jc or final_accent_only(ja, jb) or jb == ja):
                choice, why = A, 'A-final-accent'
            elif final_accent_only(ja, jb) and deaccent(jc) == deaccent(ja) and jc[-1] in 'àèìòù':
                choice, why = A, 'A-final-accent'
        nxt = T3[e]['t'] if e < len(T3) else ''
        SIG = re.compile(r"(?i)espl?.{0,6}razione ne. .u.uro|esploratore ritorna|introduzione , \\d")
        PUNCT = set('.,;:!?')
        internal = lambda w: any(ch in 'àèìòùÀÈÌÒÙ' for ch in w.rstrip('’')[:-1]) and len(w) > 2
        if choice is None and any(SIG.search(x) for x in (ja, jb, jc)) and any(x == '' for x in (ja, jb, jc)):
            choice, why = [], 'signature'
        if choice is None and len(A) == len(B) == len(C) == 1:
            if ja in ('È', 'E') and jb in ('È', 'E') and jc in ('È', 'E') and ja == 'È':
                choice, why = A, 'A-È'
            elif deaccent(ja) == deaccent(jc) and jb == jc and internal(ja) and not internal(jc) and ja.lower() != jc.lower() and inlex(C, 1):
                internal_log.append(ja)
            elif {ja, jb, jc} == {',', '.'} and isword(nxt) and nxt[0].islower():
                choice, why = [','], 'comma-before-lowercase'
        if choice is None and jb == jc and jb:
            if inlex(C, 1) and not inlex(A, 1) and deaccent(ja) != deaccent(jc):
                choice, why = C, 'V-lex'
            elif inlex(C, 2) and deaccent(na) == deaccent(nc) and len(C) == 1 and len(A) > 1 and isword(jc):
                choice, why = C, 'V-joined'
        if choice is None and ja and len(A) == len(C) == 1 and inlex(A, 1) and all(isword(t) for t in A) and not inlex(C, 1) and not inlex(B, 1) and deaccent(ja) != deaccent(jc):
            choice, why = A, 'A-lex'
        if choice is None and len(A) <= 1 and len(B) <= 1 and len(C) <= 1:
            R = [x for x in dict.fromkeys((ja, jb, jc)) if x]
            VR = [x for x in R if isword(x) and valid(x)]
            if len(VR) == 1 and all(isword(x) for x in R) and all(deaccent(x).lower() != deaccent(VR[0]).lower() for x in R if x != VR[0]) and (ja and jb and jc):
                choice, why = [VR[0]], 'only-valid'
        if choice is None and ja and (deaccent(ja) != deaccent(jb)) and (deaccent(ja) != deaccent(jc)) and jb != jc:
            cands = [x for x in (A, B, C) if x and inlex(x, 1)]
            js = set(' '.join(x) for x in cands)
            if len(js) == 1 and all(isword(t) for t in cands[0]):
                choice, why = cands[0], 'one-lex'
    ctxl = ' '.join(t['t'] for t in T3[max(0, s-6):s]); ctxr = ' '.join(t['t'] for t in T3[e:e+6])
    key = rid(ref['page'], ja, jb, jc, ctxl)
    if key in DEC:
        d = DEC[key]
        d = {'A': ja, 'V1': jb, 'V3': jc, '-': ''}.get(d, d.lstrip('='))
        choice = d.split(' ') if d else []
        why = 'manual'
    if choice is None:
        # provisional: prefer V3/V1 agreement, else A
        prov = C if jb == jc else (A if A else C)
        review.append({'id': key, 'page': ref['page'], 'li': ref['li'], 'A': ja, 'V1': jb, 'V3': jc, 'l': ctxl, 'r': ctxr, 'prov': ' '.join(prov)})
        choice, why = prov, 'REVIEW'
    stats[why] += 1
    if not choice:
        pending_para = para
        continue
    emit(choice, {'page': ref['page'], 'li': ref['li'], 'brk': brk}, why, para)
    if ai is not None: out[-len(choice)]['apara'] = 'u' if L_A_unknown(ai) else ('y' if TA[ai]['para'] else 'n')

json.dump(out, open(os.path.join(D, 'resolved.json'), 'w', encoding='utf-8'), ensure_ascii=False)
json.dump(review, open(os.path.join(D, 'review.json'), 'w', encoding='utf-8'), ensure_ascii=False, indent=0)
print(stats, len(review)); print('internal:', collections.Counter(internal_log))
if len(sys.argv) > 2:
    cat = collections.Counter()
    for r in review:
        v = ('V: ' + r['V1']) if r['V1'] == r['V3'] else ('V1: %s | V3: %s' % (r['V1'], r['V3']))
        print(r['id'][:7], r['page'], r['li'], '|', r['l'][-24:], '[ A:', r['A'], '|', v, ']', r['r'][:16])
