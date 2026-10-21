# Pemisahan role DB: migrasi/owner vs aplikasi (O-010)

**Status: prosedur siap, BELUM diterapkan di produksi.** Saat ini `kran_app` adalah pemilik schema
(`platform`, `ledger`, `party`, `product`), jadi `REVOKE UPDATE/DELETE ON platform.audit_log` tidak
mengubah apa pun — pemilik tabel selalu punya hak. Tanpa pemisahan role, append-only audit hanya
dijaga trigger (defense in depth), bukan privilege.

## Target

| Role | Dipakai oleh | Hak |
|---|---|---|
| `kran_owner` | `--role=migrate`, DDL | pemilik schema/tabel; boleh `ALTER`/`GRANT` |
| `kran_app` | API, worker, `ctl` | `SELECT/INSERT/UPDATE/DELETE` pada tabel bisnis; **hanya `SELECT/INSERT`** pada `platform.audit_log`; tanpa DDL |
| `qouver` | superuser operasi | di luar aplikasi |

Audit tetap append-only di dua lapis: trigger menolak `UPDATE/DELETE`, dan role aplikasi tidak
punya privilege itu.

## Langkah (butuh superuser; jadwalkan, bukan saat jam sibuk)

```bash
# 1. Backup + siapkan sandi baru untuk kran_owner (lewat stdin, jangan argv)
podman exec qouver-postgres psql -U qouver -d postgres -c \
  "CREATE ROLE kran_owner LOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE"
podman exec -i qouver-postgres psql -U qouver -d postgres <<'SQL'
ALTER ROLE kran_owner PASSWORD :'pw';
GRANT kran_owner TO kran_app;          -- sementara: kran_app harus bisa memindahkan ownership
SQL

# 2. Pindahkan kepemilikan schema & objek (ulangi untuk schema lain bila perlu)
podman exec qouver-postgres psql -U qouver -d kran <<'SQL'
REASSIGN OWNED BY kran_app TO kran_owner;   -- menjalankan sebagai superuser
SQL

# 3. Cabut hak tulis audit dari role aplikasi, lalu uji
podman exec qouver-postgres psql -U qouver -d kran <<'SQL'
REVOKE UPDATE, DELETE, TRUNCATE ON platform.audit_log FROM kran_app;
REVOKE ALL ON SCHEMA platform, ledger, party, product FROM PUBLIC;
GRANT USAGE ON SCHEMA platform, ledger, party, product TO kran_app;
GRANT SELECT, INSERT, UPDATE, DELETE ON ALL TABLES IN SCHEMA ledger, party, product TO kran_app;
GRANT SELECT, INSERT ON platform.audit_log TO kran_app;
GRANT SELECT, INSERT, UPDATE, DELETE ON platform.param_value, platform.param_definition,
  platform.app_user, platform.session, platform.user_role, platform.role, platform.permission,
  platform.role_permission, platform.worker_heartbeat, platform.outbox, platform.inbox,
  platform.idempotency_key, platform.business_date TO kran_app;
GRANT USAGE, SELECT ON ALL SEQUENCES IN SCHEMA platform, ledger, party, product TO kran_app;
SQL
```

Daftar tabel di atas harus disesuaikan dengan schema aktual (`\dt platform.*`). **Jangan** memakai
`GRANT ALL ON ALL TABLES` untuk `platform`, karena itu mengembalikan hak tulis audit.

## Verifikasi wajib

```bash
# 4. Role aplikasi TIDAK boleh mengubah audit
podman exec qouver-postgres psql -U kran_app -d kran -c \
  "UPDATE platform.audit_log SET action = action WHERE seq = (SELECT max(seq) FROM platform.audit_log)"
# harapan: ERROR: permission denied for table audit_log

# 5. API tetap sehat dengan role aplikasi
curl -s -o /dev/null -w '%{http_code}\n' http://127.0.0.1:8095/readyz   # 200
systemctl --user is-active kran-api kran-worker

# 6. Migrasi tetap bisa dijalankan role owner (env migrasi terpisah)
KRAN_DATABASE_URL="<url kran_owner>" LD_LIBRARY_PATH=/srv/qouver/apps/kran/lib \
  /srv/qouver/apps/kran/bin/kran-api --role=migrate --check
```

## Rollback

- `GRANT UPDATE, DELETE, TRUNCATE ON platform.audit_log TO kran_app;`
- `REASSIGN OWNED BY kran_owner TO kran_app;` (bila perlu kembali ke kondisi lama)
- Kembalikan env ke URL lama, restart, `/readyz` 200.

## Catatan

- Deploy saat ini memakai **satu** `KRAN_DATABASE_URL` untuk migrasi dan runtime. Pemisahan baru
  benar-benar berlaku setelah deploy memakai dua URL (`KRAN_MIGRATE_DATABASE_URL` untuk
  `--role=migrate`, `KRAN_DATABASE_URL` untuk api/worker/ctl). Itu perubahan kode + env di server;
  jangan lakukan setengah jalan: bila hanya ownership yang dipindah tanpa env migrasi, deploy
  berikutnya gagal di langkah migrasi.
- Catat tanggal, role, dan hasil verifikasi di `docs/PROGRESS.md`.
