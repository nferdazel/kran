#!/usr/bin/env bash
# migrate.sh — migrasi SQL CBS (spec §21.6, §21.4 #8, §21.7). MANUAL / opt-in.
#
#   migrate.sh --check            periksa urutan/drift tanpa menulis
#   migrate.sh --up               terapkan migrasi expand-only yang belum tercatat
#   migrate.sh --contract --yes   migrasi contract (drop/rename/ketat); wajib --yes
#   migrate.sh --down --yes [N]   rollback N migrasi terakhir; wajib --yes
#
# Menjalankan role migrate dari binary multi-role (spec §26.1 #5):
#   <bin> --role=migrate <subperintah>
#
# BELUM PERNAH DIJALANKAN DI SERVER (T-013): flag CLI role migrate belum
# diimplementasikan (Fase 0). Kontrak flag mengikuti spec §21.6.
set -euo pipefail

APP_DIR="${CBS_APP_DIR:-/srv/qouver/apps/cbs}"
BIN="${CBS_MIGRATE_BIN:-$APP_DIR/bin/cbs-api}"

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
  --check)
    exec "$BIN" --role=migrate --check "$@"
    ;;
  --up)
    exec "$BIN" --role=migrate --up "$@"
    ;;
  --contract)
    # Destruktif (drop/rename/ketat) — hanya manual setelah rilis stabil (§21.4).
    if ! has_yes "$@"; then
      echo "ERROR: --contract butuh --yes (migrasi destruktif, opt-in manual)" >&2
      exit 2
    fi
    exec "$BIN" --role=migrate --contract "$@"
    ;;
  --down)
    if ! has_yes "$@"; then
      echo "ERROR: --down butuh --yes (rollback opt-in manual)" >&2
      exit 2
    fi
    exec "$BIN" --role=migrate --down "$@"
    ;;
  *)
    usage
    ;;
esac
