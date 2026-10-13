# Runbook — DB dev (uji integrasi)

**Ringkas**: uji integrasi CBS memakai database `cbs_dev` di Postgres server, bukan Postgres
lokal. Akses dari laptop lewat tunnel SSH. Keputusan & alasan: `docs/DECISIONS.md` D-004.

## 1. Aktifkan

```sh
./task devdb up        # buka tunnel 127.0.0.1:55432 -> server 127.0.0.1:5432
./task devdb status    # cek koneksi + database
./task test            # uji integrasi ikut jalan (CBS_DATABASE_URL terbaca dari .local/dev.env)
./task devdb down      # tutup tunnel setelah selesai
```

Bila `CBS_DATABASE_URL` kosong atau tunnel mati, uji integrasi **melewati dirinya sendiri**
(tercetak `SKIP`), bukan gagal — pola yang sama dipakai repo keluarga `cbs-core`
(env `CBS_TEST_DB_DSN`).

## 2. Berkas & kredensial

- `.local/dev.env` (gitignored, mode 600) berisi `CBS_DATABASE_URL`. Buat ulang lewat
  prosedur di §4 bila hilang. **Jangan** pernah menyalin nilai ini ke dokumen/commit.
- Tunnel memakai `ControlMaster` di `.local/devdb.sock`; `ControlPersist=600`
  sehingga perintah `ssh` berikutnya tidak perlu handshake ulang.

## 3. Batas (jangan dilewati)

- Hanya menyentuh DB `cbs_dev` dan role `cbs_dev`. DB `cbs` (milik `cbs-core`) **tidak disentuh**.
- Tidak ada perubahan kuadlet/container/config/backup/hook di server.
- Tidak ada data nyata di DB dev; data uji selalu sintetis (AGENTS.md §3).

## 4. Provisioning awal (sekali, 2026-10-13)

Dijalankan sebagai `sachiel` di server, memakai `podman exec qouver-postgres`:

```sh
# role + database
psql -U qouver -c "CREATE ROLE cbs_dev LOGIN"          # idempotent (cek pg_roles dulu)
psql -U qouver -c "ALTER ROLE cbs_dev PASSWORD '<rahasia>'"
psql -U qouver -c "CREATE DATABASE cbs_dev OWNER cbs_dev"
# ekstensi (spec §9.1)
psql -U cbs_dev -d cbs_dev -c "CREATE EXTENSION pgcrypto; CREATE EXTENSION pg_trgm; CREATE EXTENSION btree_gist;"
```

Password di-generate acak (`openssl rand -hex 24`) dan hanya ada di `.local/dev.env`.
