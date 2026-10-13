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

## Catatan operasional (tambahan T-004, 2026-10-13)

### libpq untuk `db_connector`

`db_connector` (db_postgres) memuat `libpq.dylib` saat runtime. Di macOS/Homebrew
library-nya ada di `opt/libpq/lib`, yang tidak ada di jalur pencarian default. Tambahkan ke
`.local/dev.env` (mesin-lokal, gitignored):

```sh
DYLD_FALLBACK_LIBRARY_PATH=/opt/homebrew/opt/libpq/lib
```

Gejala bila lupa: `could not load: libpq.dylib`.

### Umur tunnel

Master koneksi SSH menutup tunnel setelah idle (`ControlPersist`, default 600 detik) — test
integrasi panjang bisa terputus dengan `Connection refused`. Untuk sesi kerja, set di
`.local/dev.env`:

```sh
CBS_DEVDB_PERSIST=7200
```

`./task devdb up` idempotent (tunnel yang sudah jalan tidak dibuka dua kali).

### Migrasi & status

```sh
./task dbtools validate   # tanpa DB: urutan + berkas + penjaga expand-only
./task dbtools migrate    # butuh CBS_DATABASE_URL; idempotent
./task dbtools status     # daftar migrasi + deteksi berkas yang isinya berubah
```

Test integrasi `modules/platform/tests/itplatform.nim` **menghapus schema `platform`**
(termasuk isi `audit_log`) lalu menerapkan ulang migrasi. Jangan arahkan
`CBS_DATABASE_URL` ke DB yang datanya berharga.
