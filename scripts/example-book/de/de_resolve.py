# Applies the decision rules to the aligned regions; writes resolved.json (tokens), review.json (open), refdiff.json (OCR unanimous, reference differs).
import pickle, sys, os, json, re, collections, hashlib, unicodedata
D = sys.argv[1]
L3, S, regions, R = pickle.load(open(os.path.join(D, 'merge.pkl'), 'rb'))
T3 = S[0]; REF = S[4]
DEC = {}
p = os.path.join(D, 'decisions.json')
if os.path.exists(p): DEC = json.load(open(p, encoding='utf-8'))
def isword(t): return bool(re.match(r"[^\W_]", t))
def fold(s): return ''.join(c for c in unicodedata.normalize('NFD', s) if unicodedata.category(c) != 'Mn').lower().replace('ß', 'ss')
def lev(a, b):
    if abs(len(a) - len(b)) > 3: return 9
    pr = list(range(len(b) + 1))
    for i, ca in enumerate(a, 1):
        cu = [i]
        for j, cb in enumerate(b, 1): cu.append(min(pr[j] + 1, cu[-1] + 1, pr[j - 1] + (ca != cb)))
        pr = cu
    return pr[-1]
def rid(page, c, ctx): return hashlib.md5(('%s|%s|%s' % (page, '|'.join(c), ctx)).encode()).hexdigest()[:7]

items = []
for r in regions:
    if r[0] == 'eq':
        i = r[1]
        items.append(([[T3[i]['t']]] + [[S[k + 1][j]['t']] for k, j in enumerate(r[2])], i, i + 1, [r[2][3], r[2][3] + 1]))
    else:
        (s, e), oth = r[1], r[2]
        C = [[t['t'] for t in T3[s:e]]] + [[t['t'] for t in S[k + 1][a:b]] for k, (a, b) in enumerate(oth)]
        if len(set(len(c) for c in C)) == 1 and len(C[0]) > 1:
            for k in range(len(C[0])): items.append(([[c[k]] for c in C], s + k, s + k + 1, [oth[3][0] + k, oth[3][0] + k + 1]))
        else: items.append((C, s, e, list(oth[3])))

def classify(o, r):
    """o: OCR tokens (unanimous), r: reference tokens."""
    jo, jr = ' '.join(o), ' '.join(r)
    wo = [t for t in o if isword(t)]; wr = [t for t in r if isword(t)]
    if wo == wr:
        po = [t for t in o if not isword(t)]; pr = [t for t in r if not isword(t)]
        if any(x in '»«‚’' for x in po + pr) and [x for x in po if x not in '»«‚’'] == [x for x in pr if x not in '»«‚’']: return 'quote'
        return 'punct'
    if [w.lower() for w in wo] == [w.lower() for w in wr]: return 'case'
    if [fold(w) for w in wo] == [fold(w) for w in wr]: return 'umlaut-ß'
    if len(wo) == len(wr):
        d = max(lev(a, b) for a, b in zip(wo, wr))
        if d <= 2: return 'small'
        return 'word'
    if ''.join(wo).lower() == ''.join(wr).lower(): return 'spacing'
    return 'struct'

out = []; review = []; refdiff = []; stats = collections.Counter()
pending_para = False
for C, s, e, rr in items:
    ref = T3[s] if s < e and s < len(T3) else T3[max(0, min(s, len(T3)) - 1)]
    para = any(T3[i]['para'] for i in range(s, e)) or pending_para; pending_para = False
    brk = any(T3[i].get('brk') for i in range(s, e))
    rpara = any(REF[i]['para'] for i in range(rr[0], min(rr[1], len(REF))))
    J = [' '.join(c) for c in C]; o = J[:4]; rf = J[4]
    ctxl = ' '.join(t['t'] for t in T3[max(0, s - 6):s]); ctxr = ' '.join(t['t'] for t in T3[e:e + 6])
    key = rid(ref['page'], J, ctxl)
    choice = None; why = None; cat = None
    if len(set(o)) == 1:
        choice = C[0]
        if rf == o[0]: why = 'agree'
        else:
            cat = classify(C[0], C[4]); why = 'ref:' + cat
    else:
        m = [c for c, j in zip(C[:4], o) if j == rf]
        if m: choice, why = m[0], 'ref-confirms-%d' % len(m)
    if key in DEC:
        d = DEC[key]
        d = {'V3': o[0], 'V1': o[1], 'V36': o[2], 'R2': o[3], 'REF': rf, '-': ''}.get(d, d.lstrip('='))
        choice = d.split(' ') if d else []; why = 'manual' if cat is None else 'image:' + cat
    rec = {'id': key, 'page': ref['page'], 'li': ref['li'], 'o': o, 'ref': rf, 'l': ctxl, 'r': ctxr}
    if choice is None:
        cnt = collections.Counter(o).most_common()
        prov = cnt[0][0].split(' ') if cnt[0][0] else []
        rec['prov'] = ' '.join(prov); review.append(rec); choice, why = prov, 'REVIEW'
    elif (cat or why == 'ref-confirms-1') and key not in DEC:
        rec['cat'] = cat or 'confirm1'; refdiff.append(rec)
    stats[why] += 1
    if not choice:
        pending_para = para; continue
    for k, t in enumerate(choice):
        out.append({'t': t, 'page': ref['page'], 'li': ref['li'], 'para': para if k == 0 else False, 'brk': brk and k == 0, 'src': why, 'rpara': rpara if k == 0 else False})
json.dump(out, open(os.path.join(D, 'resolved.json'), 'w', encoding='utf-8'), ensure_ascii=False)
json.dump(review, open(os.path.join(D, 'review.json'), 'w', encoding='utf-8'), ensure_ascii=False, indent=0)
json.dump(refdiff, open(os.path.join(D, 'refdiff.json'), 'w', encoding='utf-8'), ensure_ascii=False, indent=0)
print(sorted(stats.items()), 'review', len(review))
if len(sys.argv) > 2:
    sel = sys.argv[2]
    if sel == 'review':
        for r in review: print(r['id'], r['page'], '|', r['l'][-28:], '[', ' | '.join(r['o']), '| REF:', r['ref'], ']', r['r'][:18])
    else:
        for r in refdiff:
            if r['cat'] == sel: print(r['id'], r['page'], '|', r['l'][-22:], '[', r['o'][0], '| REF:', r['ref'], ']', r['r'][:14])
