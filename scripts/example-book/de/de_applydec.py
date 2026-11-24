# gathers dec*.txt ("id value"; value = V3|V1|V36|R2|REF|-|=literal tokens) into decisions.json
import json, sys, os
D = sys.argv[1]; out = {}
for fn in sorted(os.listdir(D)):
    if fn.startswith('dec') and fn.endswith('.txt'):
        for line in open(os.path.join(D, fn), encoding='utf-8'):
            line = line.rstrip('\n')
            if not line or line.startswith('#'): continue
            k, _, v = line.partition(' ')
            out[k] = v
json.dump(out, open(os.path.join(D, 'decisions.json'), 'w', encoding='utf-8'), ensure_ascii=False, indent=0)
print('decisions', len(out))
