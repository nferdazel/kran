#!/usr/bin/env bash
# rollback.sh — manual: kembali ke image & web sebelumnya (spec §21.6, §21.4 #7/#11).
#
# Sejak layanan API/worker dijalankan sebagai container quadlet (D-066), rollback **bukan** menyalin
# biner: yang dipakai container adalah image `localhost/kran-api:local`, jadi rollback = mengembalikan
# tag `:local` ke image `:prev` (cadangan yang dibuat deploy sebelum build baru), lalu restart unit.
# Biner host `bin/kran-api` hanya dipakai gate deploy (FREEZE/MIGRATION) yang berjalan di host; bila
# `.prev`-nya ada, ikut dipulihkan supaya gate berikutnya tidak memakai versi yang salah.
#
# TIDAK menyentuh DB. Aman karena migrasi expand-only (§21.4): skema baru tetap
# kompatibel dengan binary lama, jadi rollback binary tidak butuh migrasi balik.
#
# Usage: rollback.sh
set -euo pipefail

APP_DIR="${KRAN_APP_DIR:-/srv/qouver/apps/kran}"
BIN="$APP_DIR/bin/kran-api"
BIN_PREV="$APP_DIR/bin/kran-api.prev"
UNIT_DIR="${KRAN_UNIT_DIR:-$HOME/.config/containers/systemd}"
NATIVE_DIR="$HOME/.config/systemd/user"
HEALTH_URL="${KRAN_HEALTH_URL:-http://127.0.0.1:8095/readyz}"
IMAGE_LOCAL="localhost/kran-api:local"
IMAGE_PREV="localhost/kran-api:prev"

die() { echo "ERROR: $*" >&2; exit 1; }

# Jalur ini hanya benar untuk layanan quadlet. Kalau unit native masih ada, nama yang sama menang
# dan `systemctl restart kran-api` menjalankan biner lama — rollback akan tampak sukses tanpa efek.
[ -f "$UNIT_DIR/kran-api.container" ] || die "$UNIT_DIR/kran-api.container tidak ada — layanan bukan quadlet; ini bukan jalur rollback yang benar"
for native in kran-api.service kran-worker.service; do
  [ -e "$NATIVE_DIR/$native" ] && die "$NATIVE_DIR/$native masih ada — unit native menutupi quadlet; pindahkan dulu"
done

podman image exists "$IMAGE_PREV" || die "image $IMAGE_PREV tidak ada — tidak ada image sebelumnya untuk rollback"

echo "==> rollback image: $IMAGE_PREV -> $IMAGE_LOCAL"
podman tag "$IMAGE_PREV" "$IMAGE_LOCAL"

if [ -f "$BIN_PREV" ]; then
  echo "==> rollback biner gate: $BIN_PREV -> $BIN"
  cp -f "$BIN_PREV" "$BIN"
  chmod +x "$BIN"
else
  echo "==> WARN: $BIN_PREV tidak ada; biner gate (FREEZE/MIGRATION) dibiarkan apa adanya"
fi

if [ -d "$APP_DIR/web.prev" ]; then
  echo "==> rollback web: web.prev -> web"
  rm -rf "$APP_DIR/web"
  mv "$APP_DIR/web.prev" "$APP_DIR/web"
fi

# Unit yang diganti deploy terakhir (cadangan `.prev` dibuat `sync_units`).
for prev in "$UNIT_DIR"/*.container.prev; do
  [ -e "$prev" ] || continue
  target="${prev%.prev}"
  cp -f "$prev" "$target" && echo "==> rollback unit: $(basename "$target")"
done

systemctl --user daemon-reload
systemctl --user restart kran-api
systemctl --user restart kran-worker

# Rollback tanpa bukti layanan sehat = "selesai palsu"; poll yang sama dengan deploy.
healthy=0
for _ in {1..15}; do
  if curl -fsS --max-time 3 "$HEALTH_URL" >/dev/null 2>&1; then
    healthy=1
    break
  fi
  sleep 2
done
[ "$healthy" -eq 1 ] || die "$HEALTH_URL tidak sehat setelah rollback (periksa: journalctl --user -u kran-api -n 50)"
echo "==> rollback selesai: $HEALTH_URL sehat (DB tidak disentuh)"
