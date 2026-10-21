# Restore drill PostgreSQL (bulanan) — O-007

Backup yang tidak pernah diuji pulih bukan backup. Prosedur ini membuktikan dump harian
`/srv/qouver/backups/postgres/daily/*.dump` bisa dipulihkan **tanpa menyentuh** DB produksi.

Jadwal: **bulanan**, setelah backup 02:00 (mis. tanggal 1). Perkiraan waktu: < 2 menit untuk DB
sebesar `kran` saat ini.

## Aturan aman

- Nama DB latihan **wajib** mengandung `_verify` (`kran_verify_restore_YYYYMMDD`), karena skrip
  backup mengecualikan pola `%_verify%` (O-002) — latihan tidak ikut ter-backup.
- **Jangan** restore ke DB `kran`. Jangan mengubah/menghapus dump.
- Restore **tanpa** `--no-owner` di cluster yang sama: role (`kran_app`, `qouver`) sudah ada dan
  dump membawa `ALTER ... OWNER TO`. Drill 21 Okt 2026 membuktikan `--no-owner` membuat schema
  dimiliki `qouver`, lalu `kran_app` kena `permission denied for schema platform` saat
  `ctl verify-audit` — bukan kegagalan dump, tetapi hasil drill yang menyesatkan.
- Jangan mencetak isi `KRAN_DATABASE_URL` (berisi kata sandi).

## Langkah

```bash
# 1. Pilih dump terbaru
ls -1t /srv/qouver/backups/postgres/daily/kran_*.dump | head -1

# 2. Buat DB latihan (pola _verify = dikecualikan dari backup)
DRILL=kran_verify_restore_$(date +%Y%m%d)
podman exec qouver-postgres psql -U qouver -d postgres -tAc "DROP DATABASE IF EXISTS $DRILL"
podman exec qouver-postgres psql -U qouver -d postgres -tAc "CREATE DATABASE $DRILL"

# 3. Restore
DUMP=/srv/qouver/backups/postgres/daily/kran_YYYY-MM-DD_02-00-01.dump
time podman exec -i qouver-postgres pg_restore -U qouver -d "$DRILL" < "$DUMP"
# harapan: exit 0, tidak ada baris stderr

# 4. Bandingkan hitungan dengan produksi
for t in platform.schema_migration ledger.journal platform.audit_log party.party platform.outbox; do
  echo -n "$t: restore="
  podman exec qouver-postgres psql -U qouver -d "$DRILL" -tAc "select count(*) from $t" | tr -d '\n'
  echo -n " produksi="
  podman exec qouver-postgres psql -U qouver -d kran -tAc "select count(*) from $t"
done

# 5. Verifikasi rantai audit di DB hasil restore (tanpa mencetak URL)
URL=$(grep '^KRAN_DATABASE_URL=' /srv/qouver/apps/kran/env/kran-prod.env | cut -d= -f2-)
URL=${URL/@qouver-postgres:/@127.0.0.1:}; URL=${URL%/*}/$DRILL
KRAN_DATABASE_URL="$URL" LD_LIBRARY_PATH=/srv/qouver/apps/kran/lib \
  /srv/qouver/apps/kran/bin/kran-api --role=ctl verify-audit
# harapan: "rantai audit utuh (N entri)", exit 0

# 6. Bersihkan
podman exec qouver-postgres psql -U qouver -d postgres -tAc "DROP DATABASE $DRILL"
podman exec qouver-postgres psql -U qouver -d postgres -tAc \
  "select count(*) from pg_database where datname='$DRILL'"   # harapan: 0
```

## Bukti drill 21 Okt 2026

- Dump: `kran_2026-10-21_02-00-01.dump` (113 KB), DB latihan `kran_verify_restore_20261021`.
- `pg_restore` exit 0, 0 baris stderr, durasi 1 detik; schema dimiliki `kran_app`.
- Hitungan restore == produksi: `schema_migration` 35, `journal` 0, `audit_log` 5, `party` 0,
  `outbox` 0; 32 tabel (`platform`/`ledger`/`party`/`product`), 3 trigger audit.
- `ctl verify-audit`: **rantai audit utuh (5 entri)**, exit 0.
- DB latihan dihapus; `pg_database` count 0.

## Bila gagal

- `pg_restore` exit ≠ 0: simpan `stderr`, jangan hapus DB latihan sebelum dicatat; periksa ruang
  disk (`df -h /srv`), versi image Postgres, dan apakah dump terpotong (`pg_restore -l`).
- `verify-audit` gagal: catat pesan; jangan menganggap dump baik. Eskalasi ke pemilik.
- Catat hasil (tanggal, dump, durasi, hitungan, exit code) di `docs/PROGRESS.md`.
