#!/bin/sh
# Menyusun satu bagian CHANGELOG (Keep a Changelog) dari Conventional Commits, lalu
# menaruhnya di depan `CHANGELOG.md`. Dipakai `./task release`; tidak dipanggil saat deploy.
set -eu

version=${1:-}
from_tag=${2:-}
to_ref=${3:-HEAD}
notes_out=${4:-}

if [ -z "$version" ]; then
  echo "usage: $0 <version> [from-tag] [to-ref] [notes-file]" >&2
  exit 1
fi

root=$(cd "$(dirname "$0")/.." && pwd)
range=$to_ref
if [ -n "$from_tag" ]; then
  range="$from_tag..$to_ref"
fi

tmpd=$(mktemp -d)
trap 'rm -rf "$tmpd"' EXIT
: >"$tmpd/added"
: >"$tmpd/changed"
: >"$tmpd/fixed"
: >"$tmpd/ops"

git log "$range" --format='%s' | while IFS= read -r line; do
  [ -n "$line" ] || continue
  case "$line" in
    "chore: release"* | "chore(release):"*) continue ;;
  esac

  case "$line" in
    feat*) group=added ;;
    fix*) group=fixed ;;
    perf* | refactor*) group=changed ;;
    ops* | ci* | deploy*) group=ops ;;
    *) continue ;;
  esac
  # Hanya prefix Conventional Commit yang sah (`feat(scope): ` / `fix: `), bukan kata biasa.
  prefix=${line%%:*}
  case "$prefix" in
    feat | feat\(*\) | fix | fix\(*\) | perf | perf\(*\) | refactor | refactor\(*\) | \
      ops | ops\(*\) | ci | ci\(*\) | deploy | deploy\(*\)) ;;
    *) continue ;;
  esac

  desc=${line#*: }
  first=$(printf '%s' "$desc" | cut -c1 | tr '[:lower:]' '[:upper:]')
  desc="$first$(printf '%s' "$desc" | cut -c2-)"
  scope=""
  case "$prefix" in
    *"("*) scope=$(printf '%s' "$prefix" | sed -n 's/.*(\([^)]*\)).*/\1/p') ;;
  esac
  # Scope `web`/`ui` tidak dipajang: hampir semua perubahan UI menyentuhnya, jadi tidak
  # menambah informasi di changelog.
  case "$scope" in
    web | ui) scope="" ;;
  esac
  if [ -n "$scope" ]; then
    printf '**%s:** %s\n' "$scope" "$desc" >>"$tmpd/$group"
  else
    printf '%s\n' "$desc" >>"$tmpd/$group"
  fi
done

block="$tmpd/block"
{
  printf '## [%s] - %s\n\n' "$version" "$(date -u +%Y-%m-%d)"
  for pair in "Added:$tmpd/added" "Changed:$tmpd/changed" "Fixed:$tmpd/fixed" \
    "Operations:$tmpd/ops"; do
    name=${pair%%:*}
    file=${pair#*:}
    [ -s "$file" ] || continue
    printf '### %s\n' "$name"
    sed 's/^/- /' "$file"
    printf '\n'
  done
} >"$block"
# Buang baris kosong di akhir blok supaya jarak antar-entri konsisten.
sed -e :a -e '/^\n*$/{$d;N;ba' -e '}' "$block" >"$block.trim" && mv "$block.trim" "$block"

if [ -n "$notes_out" ]; then
  cp "$block" "$notes_out"
fi

changelog="$root/CHANGELOG.md"
if [ ! -f "$changelog" ]; then
  cat >"$changelog" <<'HDR'
# Changelog

All notable changes to KRAN are documented here. Format: [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
versioning: [Semantic Versioning](https://semver.org/spec/v2.0.0.html). Entri dihasilkan
`tools/gen-changelog.sh` dari Conventional Commits; jangan ditulis tangan.

HDR
fi

tmp=$(mktemp)
if grep -q '^## \[' "$changelog"; then
  sed -e '/^## \[/,$d' "$changelog" >"$tmp"
  cat "$block" >>"$tmp"
  printf '\n' >>"$tmp"
  sed -n -e '/^## \[/,$p' "$changelog" >>"$tmp"
else
  cat "$changelog" >"$tmp"
  cat "$block" >>"$tmp"
fi
mv "$tmp" "$changelog"
printf 'changelog: entri %s ditambahkan\n' "$version"
