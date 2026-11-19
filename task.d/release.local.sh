#!/usr/bin/env sh
# cbs release hook: stamps the new version everywhere it is written by hand.
# Called by task.d/release.sh as: sh task.d/release.local.sh <new> <old>
set -eu
cd "$(dirname "$0")/.."

new=$1

sed -i.bak -e "s/^version *= *\"[^\"]*\"/version     = \"$new\"/" kran.nimble
rm -f kran.nimble.bak
sed -i.bak -e "s/\"version\": *\"[^\"]*\"/\"version\": \"$new\"/" package.json
rm -f package.json.bak
sh tools/gen-version.sh

# gen-changelog writes the new section into CHANGELOG.md itself; the tag v<new> does not exist
# yet, so the range starts at the newest release tag.
from=$(git describe --tags --abbrev=0 --match 'v[0-9]*' 2>/dev/null || true)
bash tools/gen-changelog.sh "$new" "$from" HEAD || {
  printf '   CHANGELOG: generation failed for v%s\n' "$new" >&2
  exit 1
}
printf '   CHANGELOG: v%s section written\n' "$new"

git add VERSION kran.nimble package.json CHANGELOG.md \
  apps/api/src/version_gen.nim apps/web/src/lib/version.ts
