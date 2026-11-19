#!/usr/bin/env sh
#
# Canonical release for every qouver repo. Vendored byte-identically; fix it in
# the server repo and copy it out again (docs/CICD_V2_ROLLOUT.md).
#
#   sh task.d/release.sh [major|minor|patch] [--skip-check] [--push] [--current]
#
# With no bump argument the level is inferred from the conventional commits since
# the last vX.Y.Z tag (feat -> minor, feat!/BREAKING CHANGE -> major, else patch).
# `--current` tags the VERSION already on disk instead of bumping it; that is what
# a first release needs, when VERSION was written before the tag existed.
#
# What it does, in this order:
#   1. refuse a dirty working tree, a missing/invalid VERSION, or no new commits
#   2. run ./task gate-full unless --skip-check (a release that skips its gate says so)
#   3. write VERSION, run the optional repo hook task.d/release.local.sh <new> <old>
#   4. commit "chore(release): vX.Y.Z" and create an annotated tag vX.Y.Z
#   5. never push unless --push is given: pushing main is what deploys
#
# The hook owns everything that is repo-specific: stamping the new version into
# the manifests, moving the CHANGELOG's Unreleased section, regenerating a
# version module. It stages what it wrote with git add; this script commits
# whatever is staged.
#
# Exit codes: 0 released, 1 refused or failed (nothing half-written that git did not commit).
set -eu

ROOT=$(cd -- "$(dirname -- "$0")/.." && pwd)
cd "$ROOT"

log() { printf '\n== %s\n' "$*"; }
info() { printf '   %s\n' "$*"; }
die() { printf '\n!! FAILED: %s\n' "$*" >&2; exit 1; }

BUMP=""
SKIP_CHECK=0
PUSH=0
CURRENT=0
for arg in "$@"; do
  case "$arg" in
    major | --major) BUMP="major" ;;
    minor | --minor) BUMP="minor" ;;
    patch | --patch) BUMP="patch" ;;
    --skip-check) SKIP_CHECK=1 ;;
    --push) PUSH=1 ;;
    --no-push) PUSH=0 ;;
    --current) CURRENT=1 ;;
    -h | --help)
      printf 'usage: sh task.d/release.sh [major|minor|patch] [--skip-check] [--push] [--current]\n'
      exit 0
      ;;
    *) die "unknown release argument: $arg" ;;
  esac
done

[ -f "$ROOT/VERSION" ] || die "VERSION is missing"
CUR=$(tr -d ' \n\r' <"$ROOT/VERSION")
case "$CUR" in
  *[!0-9.]* | *..* | .* | *. | "") die "VERSION '$CUR' is not plain semver X.Y.Z" ;;
  *.*.*) ;;
  *) die "VERSION '$CUR' is not semver X.Y.Z" ;;
esac
MAJOR=$(printf '%s' "$CUR" | cut -d. -f1)
MINOR=$(printf '%s' "$CUR" | cut -d. -f2)
PATCH=$(printf '%s' "$CUR" | cut -d. -f3)

[ -z "$(git status --porcelain --untracked-files=no)" ] ||
  die "working tree is dirty: commit or stash before releasing (untracked files are ignored)"

LAST_TAG=$(git describe --tags --abbrev=0 --match 'v[0-9]*' 2>/dev/null || true)
if [ -n "$LAST_TAG" ] && [ "$(git rev-list --count "$LAST_TAG..HEAD")" -eq 0 ]; then
  die "no commits since $LAST_TAG: nothing to release"
fi

if [ "$CURRENT" -eq 1 ]; then
  NEW="$CUR"
  log "release v$NEW (tagging VERSION as it stands)"
  if git rev-parse -q --verify "refs/tags/v$NEW" >/dev/null; then
    die "tag v$NEW already exists"
  fi
else
  if [ -z "$BUMP" ]; then
    RANGE="HEAD"
    [ -n "$LAST_TAG" ] && RANGE="$LAST_TAG..HEAD"
    MSGS=$(git log "$RANGE" --format='%s%n%b')
    if printf '%s\n' "$MSGS" | grep -qE '^[a-z]+(\([^)]*\))?!:|BREAKING CHANGE:'; then
      BUMP="major"
    elif printf '%s\n' "$MSGS" | grep -qE '^feat(\([^)]*\))?:'; then
      BUMP="minor"
    else
      BUMP="patch"
    fi
  fi

  case "$BUMP" in
    major) MAJOR=$((MAJOR + 1)); MINOR=0; PATCH=0 ;;
    minor) MINOR=$((MINOR + 1)); PATCH=0 ;;
    patch) PATCH=$((PATCH + 1)) ;;
  esac
  NEW="$MAJOR.$MINOR.$PATCH"
  log "release v$NEW (from v$CUR, $BUMP bump)"
fi

if [ "$SKIP_CHECK" -eq 0 ]; then
  [ -x "$ROOT/task" ] || [ -f "$ROOT/task" ] || die "./task is missing, cannot run the release gate"
  log "release gate: ./task gate-full"
  sh "$ROOT/task" gate-full || die "release gate failed; fix it or pass --skip-check"
else
  printf '\n!! WARNING: release gate skipped (--skip-check)\n'
fi

if [ "$CURRENT" -eq 1 ]; then
  : # VERSION already holds the released number; the hook must not bump a manifest to a new one
else
  printf '%s\n' "$NEW" >"$ROOT/VERSION"
fi

# Keep a Changelog cut, one implementation for every repo: the Unreleased section becomes the
# released heading, and an empty one is left alone rather than claiming a version shipped with
# nothing in it. cbs generates its CHANGELOG from commits in its own hook, so it opts out.
if [ -f "$ROOT/CHANGELOG.md" ] && [ ! -f "$ROOT/task.d/release.changelog.local" ]; then
  if grep -q '^## \[Unreleased\]' "$ROOT/CHANGELOG.md"; then
    if awk '
      /^## \[Unreleased\]/ { inside = 1; next }
      inside && /^## \[/ { exit }
      inside && NF { found = 1 }
      END { exit(found ? 0 : 1) }
    ' "$ROOT/CHANGELOG.md"; then
      today=$(date +%Y-%m-%d)
      tmp=$(mktemp)
      awk -v ver="$NEW" -v day="$today" '
        !moved && $0 == "## [Unreleased]" {
          print "## [Unreleased]"
          print ""
          print "## [" ver "] - " day
          moved = 1
          next
        }
        { print }
      ' "$ROOT/CHANGELOG.md" >"$tmp"
      mv "$tmp" "$ROOT/CHANGELOG.md"
      git add CHANGELOG.md
      info "CHANGELOG: cut v$NEW"
    else
      info "CHANGELOG: Unreleased is empty, nothing to cut"
    fi
  fi
fi

if [ -f "$ROOT/task.d/release.local.sh" ]; then
  log "repo hook: task.d/release.local.sh"
  sh "$ROOT/task.d/release.local.sh" "$NEW" "$CUR" || die "release hook failed"
fi

git add VERSION
git diff --cached --quiet || git commit -q -m "chore(release): v$NEW"
git tag -a "v$NEW" -m "release v$NEW"

if [ "$PUSH" -eq 1 ]; then
  BRANCH=$(git rev-parse --abbrev-ref HEAD)
  log "push $BRANCH + tag v$NEW"
  git push origin "$BRANCH" || die "push failed; tag v$NEW is local"
  git push origin "v$NEW" || die "tag push failed; tag v$NEW is local"
else
  info "tag v$NEW is local (no push). Publish with: git push origin HEAD v$NEW"
fi
