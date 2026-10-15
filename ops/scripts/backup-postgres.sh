#!/usr/bin/env bash
# backup-postgres.sh — backup harian DB Postgres PRODUKSI (spec §22; O-002).
#
# Menyalin bentuk skrip server existing, dengan satu perbaikan: DB non-prod
# DIKECUALIKAN dari enumerasi (OPEN_ITEMS O-002; audit server 2026-10-13 §1 #2):
#   *_verify*, *_test, *_dev
# sehingga database verifikasi/uji tidak ikut membebani backup & disk.
#
# Sifat: idempoten (aman dijalankan berulang; nama file per tanggal ditimpa),
# retensi daily 7 / weekly 28 / monthly 84 (spec §21.1). WAL/PITR (§22) BUKAN
# tanggung jawab skrip ini — lihat catatan di docs/OPEN_ITEMS.md.
#
# BELUM PERNAH DIJALANKAN DI SERVER (T-013).
set -euo pipefail

BACKUP_ROOT="${KRAN_BACKUP_ROOT:-/srv/qouver/backups}"
PG_ROOT="$BACKUP_ROOT/postgres"
DAILY="$PG_ROOT/daily"
WEEKLY="$PG_ROOT/weekly"
MONTHLY="$PG_ROOT/monthly"
PG_CONTAINER="${KRAN_PG_CONTAINER:-qouver-postgres}"
PG_SUPERUSER="${KRAN_PG_SUPERUSER:-qouver}"

mkdir -p "$DAILY" "$WEEKLY" "$MONTHLY"
stamp="$(date +%F)"

# DB non-prod dikecualikan (O-002). Backslash = escape default LIKE di Postgres.
dbs="$(podman exec "$PG_CONTAINER" psql -U "$PG_SUPERUSER" -d postgres -tAc \
  "select datname from pg_database
     where datistemplate = false
       and datname not in ('postgres')
       and datname not like '%\\_verify%'
       and datname not like '%\\_test%'
       and datname not like '%\\_dev%'
     order by datname")"

if [ -z "$dbs" ]; then
  echo "ERROR: tidak ada DB yang lolos filter — cek koneksi/filter" >&2
  exit 1
fi

failed=0
while IFS= read -r db; do
  [ -n "$db" ] || continue
  out="$DAILY/$db-$stamp.dump"
  echo "==> dump $db -> $out"
  if ! podman exec "$PG_CONTAINER" pg_dump -U "$PG_SUPERUSER" -Fc "$db" > "$out"; then
    echo "ERROR: pg_dump $db gagal" >&2
    failed=1
    continue
  fi
  size="$(wc -c < "$out" | tr -d ' ')"
  if [ "$size" -lt 1000 ]; then
    echo "ERROR: $db dump hanya $size byte" >&2
    rm -f "$out"
    failed=1
    continue
  fi
  if ! podman exec -i "$PG_CONTAINER" pg_restore --list < "$out" >/dev/null 2>&1; then
    echo "ERROR: $db dump korup" >&2
    rm -f "$out"
    failed=1
    continue
  fi

  # Salinan mingguan (Minggu) & bulanan (tanggal 1).
  if [ "$(date +%u)" = "7" ]; then cp -f "$out" "$WEEKLY/"; fi
  if [ "$(date +%d)" = "01" ]; then cp -f "$out" "$MONTHLY/"; fi
done <<<"$dbs"

# Role/globals (lepas dari DB individual).
globals="$DAILY/globals-$stamp.sql"
echo "==> globals -> $globals"
podman exec "$PG_CONTAINER" pg_dumpall -U "$PG_SUPERUSER" --globals-only > "$globals"

# Retensi (spec §21.1).
find "$DAILY"   -maxdepth 1 -type f -mtime +7  -delete
find "$WEEKLY"  -maxdepth 1 -type f -mtime +28 -delete
find "$MONTHLY" -maxdepth 1 -type f -mtime +84 -delete

if [ "$failed" -ne 0 ]; then
  echo "ERROR: ada DB yang gagal di-backup" >&2
  exit 1
fi
echo "==> backup selesai ($stamp)"
