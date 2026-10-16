#!/usr/bin/env bash
# migrate.sh — migrasi SQL KRAN (spec §21.6, §21.4 #8, §21.7). MANUAL / opt-in.
#
#   migrate.sh --check            periksa urutan/drift tanpa menulis
#   migrate.sh --up               terapkan migrasi expand-only yang belum tercatat
#   migrate.sh --contract --yes   migrasi contract (drop/rename/ketat); wajib --yes
#   migrate.sh --down --yes N     batalkan N migrasi terakhir; wajib --yes dan N
#
# Menjalankan role migrate dari binary multi-role (spec §26.1 #5):
#   <bin> --role=migrate [--check|--up|--contract|--down N] [--root=<dir>]
#
# Kontrak di biner (T-026 untuk `--check`/`--up`, T-035 untuk sisanya): `--check` read-only (kode 1
# bila ada migrasi expand tertunda atau isinya berubah), `--up` menerapkan yang tertunda (idempoten),
# `--contract` hanya menerapkan berkas bertanda `-- dbtools:contract <alasan>` dan menolak selama
# expand masih tertunda, `--down N` butuh berkas pasangan `<nama>.down.sql`.
#
# Kode keluar biner diteruskan apa adanya: 1 salah data, 2 salah pakai, 3 dikenali tetapi ditolak pada
# keadaan itu (mis. pasangan rollback tidak ada). Prosedur + peringatannya di docs/runbooks/migrasi.md.
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
  --down --yes N     batalkan N migrasi terakhir, wajib --yes dan N
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

only_yes() {
  # Subperintah yang tidak butuh argumen lain hanya menerima `--yes`; sisa argumen ditolak, tidak
  # diabaikan diam-diam (argumen yang diabaikan terbaca seperti "sudah dijalankan seperti yang saya
  # maksud").
  local a
  for a in "$@"; do
    [ "$a" = "--yes" ] || { echo "ERROR: argumen tidak dikenal untuk $mode: $a" >&2; usage; }
  done
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
    only_yes "$@"
    exec "$BIN" --role=migrate --contract
    ;;
  --down)
    if ! has_yes "$@"; then
      echo "ERROR: --down butuh --yes (rollback opt-in manual)" >&2
      exit 2
    fi
    # N wajib dan tunggal: angka yang salah berarti skema mundur terlalu jauh, dan itu tidak bisa
    # ditebak ulang. Diteruskan apa adanya ke biner, yang juga menolaknya sendiri (kode 3).
    rollback_n=""
    for a in "$@"; do
      case "$a" in
        --yes) ;;
        '' | *[!0-9]*) echo "ERROR: jumlah rollback harus angka: $a" >&2; usage ;;
        *)
          [ -z "$rollback_n" ] || { echo "ERROR: jumlah rollback hanya boleh satu: $a" >&2; usage; }
          rollback_n="$a"
          ;;
      esac
    done
    [ -n "$rollback_n" ] || { echo "ERROR: --down butuh jumlah N (mis. --down --yes 1)" >&2; usage; }
    exec "$BIN" --role=migrate --down "$rollback_n"
    ;;
  *)
    usage
    ;;
esac
