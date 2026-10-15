#!/usr/bin/env bash
# migrate.sh — migrasi SQL KRAN (spec §21.6, §21.4 #8, §21.7). MANUAL / opt-in.
#
#   migrate.sh --check            periksa urutan/drift tanpa menulis
#   migrate.sh --up               terapkan migrasi expand-only yang belum tercatat
#   migrate.sh --contract --yes   migrasi contract (drop/rename/ketat); wajib --yes
#   migrate.sh --down --yes [N]   rollback N migrasi terakhir; wajib --yes
#
# Menjalankan role migrate dari binary multi-role (spec §26.1 #5):
#   <bin> --role=migrate [--check|--up] [--root=<dir>]
#
# Kontrak yang **sudah ada di biner** (T-026): `--check` (read-only, kode keluar 1 bila ada migrasi
# tertunda/berubah isinya) dan `--up` (default: terapkan yang tertunda, idempoten).
# `--contract` dan `--down` **belum ada** di biner dan ditolak di sini (kode 3) — bukan diam-diam
# dijalankan sebagai `--up`. Lihat docs/OPEN_ITEMS.md O-048.
#
# BELUM PERNAH DIJALANKAN DI SERVER (T-013/T-026): skrip ini masih berkas repo saja.
set -euo pipefail

APP_DIR="${KRAN_APP_DIR:-/srv/qouver/apps/kran}"
BIN="${KRAN_MIGRATE_BIN:-$APP_DIR/bin/kran-api}"

usage() {
  cat >&2 <<'USAGE'
pemakaian: migrate.sh <subperintah>
  --check            periksa drift/urutan (read-only)
  --up               terapkan migrasi expand-only
  --contract --yes   migrasi contract (drop/rename), wajib --yes
  --down --yes [N]   rollback N migrasi terakhir, wajib --yes
USAGE
  exit 2
}

has_yes() {
  local a
  for a in "$@"; do
    [ "$a" = "--yes" ] && return 0
  done
  return 1
}

[ "$#" -ge 1 ] || usage

mode="$1"
shift

case "$mode" in
  --check|--up|--contract|--down) ;;
  *) usage ;;
esac

[ -x "$BIN" ] || { echo "ERROR: $BIN tidak ada / tidak executable" >&2; exit 1; }

case "$mode" in
  --check | --up)
    # Argumen tambahan tidak diteruskan apa adanya: biner akan membacanya sebagai argumen posisi dan
    # menjawab kode 2 "argumen posisi hanya untuk --role=ctl", yang menyesatkan. `--yes` hanya milik
    # jalur destruktif di bawah.
    [ "$#" -eq 0 ] || { echo "ERROR: $mode tidak menerima argumen tambahan: $*" >&2; usage; }
    exec "$BIN" --role=migrate "$mode"
    ;;
  --contract)
    # Destruktif (drop/rename/ketat) — hanya manual setelah rilis stabil (§21.4).
    if ! has_yes "$@"; then
      echo "ERROR: --contract butuh --yes (migrasi destruktif, opt-in manual)" >&2
      exit 2
    fi
    echo "ERROR: --contract belum ada di biner (Fase 0); lihat docs/OPEN_ITEMS.md O-048" >&2
    exit 3
    ;;
  --down)
    if ! has_yes "$@"; then
      echo "ERROR: --down butuh --yes (rollback opt-in manual)" >&2
      exit 2
    fi
    echo "ERROR: --down belum ada di biner (Fase 0); lihat docs/OPEN_ITEMS.md O-048" >&2
    exit 3
    ;;
  *)
    usage
    ;;
esac
