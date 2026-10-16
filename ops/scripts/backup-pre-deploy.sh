#!/usr/bin/env bash
# backup-pre-deploy.sh — dump pra-migrasi sebelum deploy (spec §21.4 #6).
#
# Usage: backup-pre-deploy.sh [rev]     (default rev = "manual")
# Output: /srv/qouver/backups/pre-deploy/<rev>-<timestamp>.dump
#
# Dump yang tidak bisa dibaca = bukan backup: divalidasi dengan `pg_restore --list`
# (konsisten dengan backup harian §22). Tanpa secret; kredensial via env container.
#
# BELUM PERNAH DIJALANKAN DI SERVER (T-013).
set -euo pipefail

REV="${1:-manual}"
BACKUP_ROOT="${KRAN_BACKUP_ROOT:-/srv/qouver/backups}"
DEST_DIR="$BACKUP_ROOT/pre-deploy"
PG_CONTAINER="${KRAN_PG_CONTAINER:-qouver-postgres}"
PG_SUPERUSER="${KRAN_PG_SUPERUSER:-qouver}"
DB_NAME="${KRAN_DB_NAME:-kran}"

mkdir -p "$DEST_DIR"
stamp="$(date -u +%Y%m%dT%H%M%SZ)"
out="$DEST_DIR/${REV}-${stamp}.dump"

echo "==> pre-deploy dump $DB_NAME -> $out"
podman exec "$PG_CONTAINER" pg_dump -U "$PG_SUPERUSER" -Fc "$DB_NAME" > "$out"

size="$(wc -c < "$out" | tr -d ' ')"
# Ambang ukuran tetap **bukan** ukuran keberhasilan: dump DB nyaris kosong (satu tabel kosong) sah-sah
# saja kecil — dan itu persis yang membatalkan deploy pertama di D-043/T-045 (2269 byte, 1 tabel).
# Karena itu yang diperiksa isinya: dump harus bisa dibaca `pg_restore --list` dan, kalau DB memang
# punya tabel, daftar itu harus memuat definisi tabel. Ukuran hanya dipakai sebagai lantai untuk kasus
# "pg_dump menulis hampir tidak apa-apa".
if [ "$size" -lt 100 ]; then
  echo "ERROR: dump hanya $size byte — pg_dump hampir pasti gagal" >&2
  rm -f "$out"
  exit 1
fi

if ! listing="$(podman exec -i "$PG_CONTAINER" pg_restore --list < "$out" 2>/dev/null)"; then
  echo "ERROR: pg_restore --list gagal — dump korup" >&2
  rm -f "$out"
  exit 1
fi

objects="$(podman exec "$PG_CONTAINER" psql -U "$PG_SUPERUSER" -d "$DB_NAME" -Atc \
  "select count(*) from pg_class c join pg_namespace n on n.oid = c.relnamespace
    where c.relkind in ('r','p') and n.nspname not in ('pg_catalog','information_schema')" \
  | tr -d ' ')"
if [ "${objects:-0}" -gt 0 ] && ! grep -qE '(^|[^A-Z])TABLE([^A-Z]|$)' <<<"$listing"; then
  echo "ERROR: $DB_NAME punya $objects tabel tetapi dump tidak memuat definisi tabel apa pun — dump tidak lengkap" >&2
  rm -f "$out"
  exit 1
fi
if [ "${objects:-0}" -eq 0 ]; then
  echo "==> catatan: $DB_NAME masih kosong (0 tabel) — dump $size byte itu wajar untuk deploy pertama"
fi

echo "==> ok: $out ($size byte, terverifikasi)"
