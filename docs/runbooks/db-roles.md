# Pemisahan role DB: migrasi (owner) vs runtime (O-010, D-110)

**Tujuan:** audit append-only punya dua lapis — trigger (sudah ada) **dan** privilege: role runtime
tidak boleh `UPDATE/DELETE/TRUNCATE` pada `platform.audit_log`. Role owner hanya dipakai migrasi/seed.

Pendekatan yang dipakai: **role runtime terpisah**, bukan memindahkan ownership. `kran_app` tetap
pemilik schema (migrasi tidak berubah); API/worker/ctl memakai `kran_runtime`. Ini menghindari
`REASSIGN OWNED` yang bisa memutus grant dan default privilege.

| Role | Dipakai | Hak |
|---|---|---|
| `kran_app` | `--role=migrate` (deploy), seed | pemilik schema/objek, DDL |
| `kran_runtime` | api, worker, ctl | CRUD tabel bisnis; audit hanya `SELECT/INSERT`; tanpa DDL; tanpa TRUNCATE audit |

Deploy sudah mendukung ini (`ops/scripts/deploy-vps.sh`): bila `env/kran-migrate.env` ada, migrasi/
seed memakai URL di berkas itu; runtime memakai `KRAN_DATABASE_URL` seperti biasa.

## Langkah (sekali, butuh superuser; jadwalkan)

```bash
cd /srv/qouver/apps/kran

# 1. Sandi runtime baru (tidak dicetak; disimpan ke env, bukan argv)
NEW_PW="$(openssl rand -hex 24)"
printf "\\set pw '%s'\nCREATE ROLE kran_runtime LOGIN PASSWORD :'pw';\n" "$NEW_PW" \
  | podman exec -i qouver-postgres psql -U qouver -d postgres

# 2. Pindahkan URL owner ke berkas terpisah (tidak dimuat unit), lalu ganti URL runtime
python3 - "$NEW_PW" <<'PY'
import os, re, sys
pw = sys.argv[1]
base = "/srv/qouver/apps/kran/env"
prod = open(f"{base}/kran-prod.env").read().splitlines()
url = next(l.split("=", 1)[1] for l in prod if l.startswith("KRAN_DATABASE_URL="))
open(f"{base}/kran-migrate.env", "w").write("KRAN_DATABASE_URL=" + url + "\n")
os.chmod(f"{base}/kran-migrate.env", 0o600)
runtime = re.sub(r"(://[^:]+:)[^@]*(@)", r"\g<1>" + pw + r"\g<2>", url)
runtime = re.sub(r"(://)[^:]+(:)", r"\g<1>kran_runtime\g<2>", runtime, count=1)
out = []
for l in prod:
    if l.startswith("KRAN_DATABASE_URL="):
        l = "KRAN_DATABASE_URL=" + runtime
    out.append(l)
open(f"{base}/kran-prod.env", "w").write("\n".join(out) + "\n")
os.chmod(f"{base}/kran-prod.env", 0o600)
PY

# 3. Grant runtime (idempoten; jalankan sebagai superuser)
podman exec -i qouver-postgres psql -U qouver -d kran <<'SQL'
GRANT USAGE ON SCHEMA platform, ledger, party, product, deposit, teller TO kran_runtime;
GRANT SELECT, INSERT, UPDATE, DELETE ON ALL TABLES IN SCHEMA platform, ledger, party, product, deposit, teller
  TO kran_runtime;
GRANT SELECT, INSERT ON platform.audit_log TO kran_runtime;
REVOKE UPDATE, DELETE, TRUNCATE ON platform.audit_log FROM kran_runtime;
GRANT USAGE, SELECT ON ALL SEQUENCES IN SCHEMA platform, ledger, party, product, deposit, teller TO kran_runtime;
GRANT EXECUTE ON ALL FUNCTIONS IN SCHEMA platform, ledger, party, product, deposit, teller TO kran_runtime;
ALTER DEFAULT PRIVILEGES FOR ROLE kran_app IN SCHEMA platform
  GRANT SELECT, INSERT, UPDATE, DELETE ON TABLES TO kran_runtime;
ALTER DEFAULT PRIVILEGES FOR ROLE kran_app IN SCHEMA ledger
  GRANT SELECT, INSERT, UPDATE, DELETE ON TABLES TO kran_runtime;
ALTER DEFAULT PRIVILEGES FOR ROLE kran_app IN SCHEMA party
  GRANT SELECT, INSERT, UPDATE, DELETE ON TABLES TO kran_runtime;
ALTER DEFAULT PRIVILEGES FOR ROLE kran_app IN SCHEMA product
  GRANT SELECT, INSERT, UPDATE, DELETE ON TABLES TO kran_runtime;
ALTER DEFAULT PRIVILEGES FOR ROLE kran_app IN SCHEMA deposit
  GRANT SELECT, INSERT, UPDATE, DELETE ON TABLES TO kran_runtime;
ALTER DEFAULT PRIVILEGES FOR ROLE kran_app IN SCHEMA teller
  GRANT SELECT, INSERT, UPDATE, DELETE ON TABLES TO kran_runtime;
ALTER DEFAULT PRIVILEGES FOR ROLE kran_app IN SCHEMA platform
  GRANT USAGE, SELECT ON SEQUENCES TO kran_runtime;
ALTER DEFAULT PRIVILEGES FOR ROLE kran_app IN SCHEMA ledger
  GRANT USAGE, SELECT ON SEQUENCES TO kran_runtime;
ALTER DEFAULT PRIVILEGES FOR ROLE kran_app IN SCHEMA deposit
  GRANT USAGE, SELECT ON SEQUENCES TO kran_runtime;
ALTER DEFAULT PRIVILEGES FOR ROLE kran_app IN SCHEMA teller
  GRANT USAGE, SELECT ON SEQUENCES TO kran_runtime;
SQL

# 4. Cabut hak tulis pada tabel immutable (T-129/DB-1)
#    Migrasi `platform/0042` melakukan ini otomatis saat deploy. Jalankan juga di sini supaya
#    runbook tetap benar bila langkah 3 diulang (GRANT di atas memberi UPDATE/DELETE ke semua tabel).
podman exec -i qouver-postgres psql -U qouver -d kran <<'SQL'
REVOKE UPDATE, DELETE, TRUNCATE ON ledger.journal, ledger.journal_line FROM kran_runtime;
REVOKE UPDATE, DELETE, TRUNCATE ON platform.audit_log FROM kran_runtime;
REVOKE DELETE, TRUNCATE ON platform.param_value FROM kran_runtime;
SQL

# 5. Restart dengan URL runtime, lalu verifikasi
systemctl --user restart kran-api kran-worker
sleep 3
curl -s -o /dev/null -w '%{http_code}\n' http://127.0.0.1:8095/readyz          # 200
systemctl --user is-active kran-api kran-worker                                 # active active
```

**Peringatan `ALTER DEFAULT PRIVILEGES`.** Default privilege tidak bisa mengecualikan tabel
tertentu, jadi tabel immutable **baru** (mis. tabel riwayat/jurnal modul berikutnya) ikut menerima
`UPDATE/DELETE` saat dibuat. Setiap migrasi yang membuat tabel seperti itu wajib menambahkan
`REVOKE` untuk `kran_runtime` di migrasinya sendiri (contoh: `platform/0042`).

## Verifikasi wajib

```bash
# a. Runtime TIDAK boleh mengubah audit maupun jurnal (T-129/DB-1)
podman exec qouver-postgres psql -U qouver -d kran -tAc "SELECT has_table_privilege('kran_runtime','ledger.journal','UPDATE') OR has_table_privilege('kran_runtime','ledger.journal','DELETE'), has_table_privilege('kran_runtime','ledger.journal_line','UPDATE') OR has_table_privilege('kran_runtime','ledger.journal_line','DELETE'), has_table_privilege('kran_runtime','platform.audit_log','UPDATE') OR has_table_privilege('kran_runtime','platform.audit_log','DELETE')"   # harus f f f
podman exec qouver-postgres psql -U qouver -d kran -tAc "SELECT has_table_privilege('kran_runtime','platform.param_value','DELETE')"   # harus f

# b. Percobaan tulis langsung lewat role runtime: audit ditolak DB
PW=$(sed -nE 's#^KRAN_DATABASE_URL=.*://[^:]+:([^@]+)@.*#\1#p' /srv/qouver/apps/kran/env/kran-prod.env)
podman exec -e PGPASSWORD="$PW" qouver-postgres psql -h 127.0.0.1 -U kran_runtime -d kran -c \
  "UPDATE platform.audit_log SET action = action WHERE seq = (SELECT max(seq) FROM platform.audit_log)"
# harapan: ERROR: permission denied for table audit_log

# c. Runtime masih bisa menulis tabel bisnis (denyut worker menyegar)
podman exec qouver-postgres psql -U qouver -d kran -tAc \
  "select worker_name, extract(epoch from now()-last_seen_at)::int from platform.worker_heartbeat"

# d. Migrasi tetap jalan dengan role owner
URL=$(sed -n 's/^KRAN_DATABASE_URL=//p' /srv/qouver/apps/kran/env/kran-migrate.env)
URL="${URL//@qouver-postgres:/@127.0.0.1:}"
KRAN_DATABASE_URL="$URL" LD_LIBRARY_PATH=/srv/qouver/apps/kran/lib \
  /srv/qouver/apps/kran/bin/kran-api --role=migrate --check; echo "check=$?"
```

## Rollback

- Kembalikan `KRAN_DATABASE_URL` dari `kran-migrate.env` ke `kran-prod.env`, restart, `/readyz` 200.
- `REVOKE ALL ... FROM kran_runtime; DROP ROLE kran_runtime;` (opsional).
- Jangan menghapus `kran-migrate.env` selama deploy berikutnya masih butuh role owner.
