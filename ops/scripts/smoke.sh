#!/usr/bin/env bash
# smoke.sh — cek cepat pasca-deploy: /healthz, /readyz, rev artefak == berkas state
# (spec §21.6, §22).
#
# Exit 0 hanya bila liveness & readiness OK. Ketidakcocokan rev dilaporkan
# sebagai WARN (bukan FAIL): ini pemeriksaan manual, bukan gate deploy.
#
# Deploy mencatat dua rev dan artinya beda. `.deployed_rev` = rev checkout (dipakai
# replay guard). `.deployed_artifact_rev` = rev yang artefaknya benar-benar dipasang,
# dan hanya ditulis bila deploy itu menarik image API/web. `/healthz` melaporkan rev
# artefak, jadi pembandingnya `.deployed_artifact_rev` bila ada; host yang belum
# pernah menulisnya memakai `.deployed_rev` sebagai fallback.
#
# BELUM PERNAH DIJALANKAN DI SERVER (T-013).
set -euo pipefail

APP_DIR="${KRAN_APP_DIR:-/srv/qouver/apps/kran}"
STATE_FILE="$APP_DIR/.deployed_rev"
ARTIFACT_STATE_FILE="$APP_DIR/.deployed_artifact_rev"
BASE_URL="${KRAN_BASE_URL:-http://127.0.0.1:8095}"
fail=0

for ep in /healthz /readyz; do
  if curl -fsS --max-time 5 "$BASE_URL$ep" >/dev/null 2>&1; then
    printf 'OK   %s\n' "$ep"
  else
    printf 'FAIL %s\n' "$ep"
    fail=1
  fi
done

# `.deployed_artifact_rev` menang bila ada; `.deployed_rev` hanya fallback.
rev_file="$ARTIFACT_STATE_FILE"
[ -f "$rev_file" ] || rev_file="$STATE_FILE"
expected=""
if [ -f "$rev_file" ]; then expected="$(cat "$rev_file")"; fi

# Rev artefak ada di field `rev` `/healthz` (`{"rev":"<sha>","part":"web"}`). `/healthz` API
# membalas `version`, bukan `rev`, jadi berkas web yang Caddy layani dipakai bila endpoint API
# tidak memuatnya — sumbernya disebut di keluaran supaya tidak ada angka tanpa asal.
body="$(curl -fsS --max-time 5 "$BASE_URL/healthz" 2>/dev/null || echo '')"
running="$(sed -n 's/.*"rev"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' <<<"$body")"
source="$BASE_URL/healthz"
if [ -z "$running" ] && [ -f "$APP_DIR/web/healthz" ]; then
  running="$(sed -n 's/.*"rev"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$APP_DIR/web/healthz")"
  source="$APP_DIR/web/healthz"
fi

if [ -n "$expected" ] && [ -n "$running" ] && [ "$running" = "$expected" ]; then
  printf 'OK   rev == %s (%s, dari %s)\n' "$(basename "$rev_file")" "$expected" "$source"
else
  printf 'WARN rev: %s=%q healthz=%q (dari %s)\n' \
    "$(basename "$rev_file")" "$expected" "${running:-$body}" "$source"
fi

exit "$fail"
