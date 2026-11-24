# cropids.py D out.png  -> crops for every item in review.json (optionally only ids given)
import json, subprocess, sys, os
D = sys.argv[1]; out = sys.argv[2]; ids = set(sys.argv[3:])
R = [r for r in json.load(open(os.path.join(D, 'review.json'), encoding='utf-8')) if not ids or r['id'] in ids]
here = os.path.dirname(os.path.abspath(__file__))
subprocess.run([sys.executable, '-P', os.path.join(here, 'crops.py'), D, out] + ['%d:%d:%s' % (r['page'], r['li'], r['id']) for r in R])
