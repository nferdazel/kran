#!/usr/bin/env bash
# smoke.sh — cek cepat pasca-deploy: /healthz, /readyz, versi == .deployed_rev
# (spec §21.6, §22).
#
# Exit 0 hanya bila liveness & readiness OK. Ketidakcocokan versi dilaporkan
# sebagai WARN (bukan FAIL) karena endpoint versi belum pasti (lihat asumsi).
#
# ASUMSI yang belum diverifikasi: endpoint `GET /version` mengembalikan rev yang
# sama dengan isi `.deployed_rev`. Bila kontrak berubah, sesuaikan di sini.
#
# BELUM PERNAH DIJALANKAN DI SERVER (T-013).
set -euo pipefail

APP_DIR="${KRAN_APP_DIR:-/srv/qouver/apps/kran}"
STATE_FILE="$APP_DIR/.deployed_rev"
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

deployed=""
[ -f "$STATE_FILE" ] && deployed="$(cat "$STATE_FILE")"
running="$(curl -fsS --max-time 5 "$BASE_URL/version" 2>/dev/null || echo '')"
if [ -n "$deployed" ] && [ "$running" = "$deployed" ]; then
  printf 'OK   versi == .deployed_rev (%s)\n' "$deployed"
else
  printf 'WARN versi: running=%q deployed=%q\n' "$running" "$deployed"
fi

exit "$fail"
