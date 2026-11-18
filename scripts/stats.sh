#!/bin/zsh
# musset.app's counters, from the D1 database musset-stats (website/stats/schema.sql): downloads, updates and update
# checks per day, then per version and per country over the last 30 days.
#   scripts/stats.sh            the last 30 days
#   scripts/stats.sh 90         the last 90
set -euo pipefail
cd "$(dirname "$0")/../website"
DAYS="${1:-30}"
[[ "$DAYS" =~ '^[0-9]+$' ]] || { echo "usage: scripts/stats.sh [days]" >&2; exit 1; }
SINCE="date('now', '-$DAYS days')"
# wrangler answers in JSON: shown as aligned columns.
q() {
  npx --yes wrangler@4.40.0 d1 execute musset-stats --remote --json --command "$1" 2>/dev/null | python3 -I -c '
import json, sys
rows = json.load(sys.stdin)[0]["results"]
if not rows: print("  nothing yet"); sys.exit()
cols = list(rows[0])
width = {c: max(len(c), *(len(str(r[c])) for r in rows)) for c in cols}
for r in [dict(zip(cols, cols))] + rows: print("  " + "  ".join(str(r[c]).ljust(width[c]) for c in cols))'
}
echo "Per day"
q "SELECT day, SUM(CASE kind WHEN 'download' THEN n ELSE 0 END) AS downloads, SUM(CASE kind WHEN 'update' THEN n ELSE 0 END) AS updates, SUM(CASE kind WHEN 'check' THEN n ELSE 0 END) AS checks FROM counts WHERE day >= $SINCE GROUP BY day ORDER BY day DESC"
echo "Per version"
q "SELECT kind, version, SUM(n) AS n FROM counts WHERE day >= $SINCE GROUP BY kind, version ORDER BY kind, version DESC"
echo "Per country"
q "SELECT country, SUM(CASE kind WHEN 'download' THEN n ELSE 0 END) AS downloads, SUM(CASE kind WHEN 'check' THEN n ELSE 0 END) AS checks FROM counts WHERE day >= $SINCE GROUP BY country ORDER BY downloads DESC, checks DESC LIMIT 20"
