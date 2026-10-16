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
if [ "$size" -lt 10000 ]; then
  # Dump kecil itu **wajar** kalau DB-nya memang masih kosong (deploy pertama ke DB baru) — dan itu
  # kejadian nyata di D-043/T-045: guard ini sempat membatalkan deploy pertama padahal dumpnya benar
  # (874 byte, DB tanpa tabel). Jadi ukurannya dinilai bersama jumlah tabel, bukan sendirian.
  objects="$(podman exec "$PG_CONTAINER" psql -U "$PG_SUPERUSER" -d "$DB_NAME" -Atc \
    "select count(*) from pg_class c join pg_namespace n on n.oid = c.relnamespace
      where c.relkind in ('r','p') and n.nspname not in ('pg_catalog','information_schema')" \
    | tr -d ' ')"
  if [ "${objects:-0}" -eq 0 ]; then
    echo "==> catatan: $DB_NAME masih kosong (0 tabel) — dump $size byte itu wajar untuk deploy pertama"
  else
    echo "ERROR: dump hanya $size byte padahal $DB_NAME punya $objects tabel — hampir pasti gagal" >&2
    rm -f "$out"
    exit 1
  fi
fi

if ! podman exec -i "$PG_CONTAINER" pg_restore --list < "$out" >/dev/null 2>&1; then
  echo "ERROR: pg_restore --list gagal — dump korup" >&2
  rm -f "$out"
  exit 1
fi

echo "==> ok: $out ($size byte, terverifikasi)"
