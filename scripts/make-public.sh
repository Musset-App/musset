#!/bin/zsh
# Builds the open-source tree of Musset in a separate folder, with a fresh history of one commit:
# the app, its tests and scripts — not the sync server, the reports, the books in fixtures/ or the generated
# Xcode project. Then scans it for secrets with gitleaks. Nothing is pushed anywhere.
#   scripts/make-public.sh <empty-or-new-folder>
set -euo pipefail
cd "$(dirname "$0")/.."

OUT="${1:?usage: scripts/make-public.sh <folder>}"
if [ -e "$OUT" ] && [ -n "$(ls -A "$OUT" 2>/dev/null)" ]; then echo "error: $OUT is not empty" >&2; exit 1; fi
mkdir -p "$OUT"

# Every file git knows or would add, minus what stays private.
git ls-files --cached --others --exclude-standard -z \
  | grep -zvE '^(server/|reports/|research_notes/|docs/|fixtures/|Musset\.xcodeproj/|build/|\.claude/)' \
  | xargs -0 -I{} rsync -R "{}" "$OUT/"

[ -f LICENSE ] || echo "warning: no LICENSE file yet (GPL-3.0 text from https://www.gnu.org/licenses/gpl-3.0.txt)" >&2

cd "$OUT"
git init -q
git add -A
# Signed by the project, not by a person.
GIT_AUTHOR_NAME=Musset GIT_AUTHOR_EMAIL=hello@musset.app GIT_COMMITTER_NAME=Musset GIT_COMMITTER_EMAIL=hello@musset.app \
  git -c user.name=Musset -c user.email=hello@musset.app commit -q -m "Musset, open source under the GPL-3.0"
echo "Public tree: $OUT ($(git ls-files | wc -l | tr -d ' ') files)"

if command -v gitleaks >/dev/null; then
  gitleaks git --no-banner --redact . && echo "gitleaks: no secrets found"
else
  echo "warning: gitleaks not installed; scan for secrets before publishing" >&2
fi
