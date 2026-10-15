#!/usr/bin/env bash
# rollback.sh — manual: kembali ke binary & web sebelumnya (spec §21.6, §21.4 #7/#11).
#
# TIDAK menyentuh DB. Aman karena migrasi expand-only (§21.4): skema baru tetap
# kompatibel dengan binary lama, jadi rollback binary tidak butuh migrasi balik.
#
# Usage: rollback.sh
# BELUM PERNAH DIJALANKAN DI SERVER (T-013).
set -euo pipefail

APP_DIR="${KRAN_APP_DIR:-/srv/qouver/apps/kran}"
BIN="$APP_DIR/bin/kran-api"
BIN_PREV="$APP_DIR/bin/kran-api.prev"

if [ ! -f "$BIN_PREV" ]; then
  echo "ERROR: $BIN_PREV tidak ada — tidak ada binary sebelumnya untuk rollback" >&2
  exit 1
fi

echo "==> rollback binary: $BIN_PREV -> $BIN"
cp -f "$BIN_PREV" "$BIN"
chmod +x "$BIN"

if [ -d "$APP_DIR/web.prev" ]; then
  echo "==> rollback web: web.prev -> web"
  rm -rf "$APP_DIR/web"
  mv "$APP_DIR/web.prev" "$APP_DIR/web"
fi

systemctl --user restart kran-api
systemctl --user restart kran-worker
echo "==> rollback selesai (DB tidak disentuh)"
