import pickle, sys, collections, random
L3,T3,T1,TA,regions = pickle.load(open(sys.argv[1]+'/merge.pkl','rb'))
eqd = collections.Counter()
ex = collections.defaultdict(list)
for r in regions:
    if r[0]=='eq':
        a,b,c = TA[r[2]]['t'], T1[r[3]]['t'], T3[r[1]]['t']
        if not (a==b==c):
            k = 'A=V1' if a==b else 'A=V3' if a==c else 'V1=V3' if b==c else 'all'
            eqd[k]+=1; ex[k].append((a,b,c,T3[r[1]]['page']))
print(eqd)
for k in ex:
    print('##',k); 
    for e in ex[k][:int(sys.argv[2])]: print('  ',e)
random.seed(1)
ds=[r for r in regions if r[0]=='diff']
for r in random.sample(ds,int(sys.argv[3])):
    (s,e),(a1,a2),(b1,b2)=r[1:]
    pg = T3[min(s,len(T3)-1)]['page']
    print(pg, '| A:',' '.join(t['t'] for t in TA[a1:a2]),'| V1:',' '.join(t['t'] for t in T1[b1:b2]),'| V3:',' '.join(t['t'] for t in T3[s:e]))
