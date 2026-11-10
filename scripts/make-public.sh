#!/bin/zsh
# Publishes Musset's open-source tree to github.com/Musset-App/musset, signed by the project, never by a person.
#
# The public repository lives in .public/ (ignored by this one). Each run copies the app, its tests and scripts into
# it — never the sync server, the reports, the books in fixtures/, local signing files or the generated Xcode
# project — and adds one commit on top, signed « Musset <hello@musset.app> ». Hooks in .public/ refuse any commit or
# push under another name. gitleaks scans the result. Nothing is pushed unless you pass --push.
#
#   scripts/make-public.sh "What changed"          # prepare the commit in .public/
#   scripts/make-public.sh "What changed" --push   # and push it
set -euo pipefail
cd "$(dirname "$0")/.."

MESSAGE="${1:?usage: scripts/make-public.sh \"commit message\" [--push]}"
PUSH="${2:-}"
REMOTE="https://github.com/Musset-App/musset.git"
NAME="Musset"
EMAIL="hello@musset.app"
PUB=".public"

# The public clone, with the project's identity and the guards.
if [ ! -d "$PUB/.git" ]; then git clone -q "$REMOTE" "$PUB"; fi
git -C "$PUB" config user.name "$NAME"
git -C "$PUB" config user.email "$EMAIL"
mkdir -p "$PUB/.git/hooks"
cat > "$PUB/.git/hooks/pre-commit" <<EOF
#!/bin/sh
# Every commit here is signed by the project.
for who in "\$(git var GIT_AUTHOR_IDENT)" "\$(git var GIT_COMMITTER_IDENT)"; do
  case "\$who" in "$NAME <$EMAIL> "*) ;; *) echo "refused: commits here are signed $NAME <$EMAIL>, not: \${who% * *}" >&2; exit 1 ;; esac
done
EOF
cat > "$PUB/.git/hooks/pre-push" <<EOF
#!/bin/sh
# Nothing leaves with another name in it.
z=0000000000000000000000000000000000000000
while read local_ref local_sha remote_ref remote_sha; do
  [ "\$local_sha" = "\$z" ] && continue
  range="\$local_sha"; [ "\$remote_sha" != "\$z" ] && range="\$remote_sha..\$local_sha"
  bad=\$(git log --format='%an <%ae>%n%cn <%ce>' "\$range" | grep -v '^$NAME <$EMAIL>\$' | sort -u)
  if [ -n "\$bad" ]; then echo "refused: commits signed by someone else than $NAME <$EMAIL>:" >&2; echo "\$bad" >&2; exit 1; fi
done
EOF
chmod +x "$PUB/.git/hooks/pre-commit" "$PUB/.git/hooks/pre-push"

# The files to publish: what git knows here, minus what stays private.
STAGE=$(mktemp -d)
git ls-files --cached --others --exclude-standard -z \
  | grep -zvE '^(server/|reports/|research_notes/|docs/|fixtures/|Musset\.xcodeproj/|build/|\.claude/|\.public/)' \
  | xargs -0 -I{} rsync -R "{}" "$STAGE/"
rsync -a --delete --exclude .git "$STAGE/" "$PUB/"
rm -rf "$STAGE"

cd "$PUB"
git add -A
if git diff --cached --quiet; then echo "Nothing changed since the last publication."; else
  GIT_AUTHOR_NAME="$NAME" GIT_AUTHOR_EMAIL="$EMAIL" GIT_COMMITTER_NAME="$NAME" GIT_COMMITTER_EMAIL="$EMAIL" \
    git commit -q -m "$MESSAGE"
  echo "Committed in $PUB: $(git log -1 --format='%h %an <%ae> — %s')"
fi

if command -v gitleaks >/dev/null; then
  gitleaks git --no-banner --redact . && echo "gitleaks: no secrets found"
else
  echo "warning: gitleaks not installed; scan for secrets before pushing" >&2
fi

if [ "$PUSH" = "--push" ]; then git push -q origin HEAD:main && echo "Pushed to $REMOTE"; else echo "Not pushed (add --push)."; fi
