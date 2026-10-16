# Runbook — DB dev (uji integrasi)

**Ringkas**: uji integrasi KRAN memakai database `kran_dev` di Postgres server, bukan Postgres
lokal. Akses dari laptop lewat tunnel SSH. Keputusan & alasan: `docs/DECISIONS.md` D-004.

## 1. Aktifkan

```sh
./task devdb up        # buka tunnel 127.0.0.1:55432 -> server 127.0.0.1:5432
./task devdb status    # cek koneksi + database
./task test            # uji integrasi ikut jalan (KRAN_DATABASE_URL terbaca dari .local/dev.env)
./task devdb down      # tutup tunnel setelah selesai
```

Bila `KRAN_DATABASE_URL` kosong atau tunnel mati, uji integrasi **melewati dirinya sendiri**
(tercetak `SKIP`), bukan gagal — pola yang sama dipakai repo keluarga `cbs-core`
(env `KRAN_TEST_DB_DSN`).

## 2. Berkas & kredensial

- `.local/dev.env` (gitignored, mode 600) berisi `KRAN_DATABASE_URL`. Buat ulang lewat
  prosedur di §4 bila hilang. **Jangan** pernah menyalin nilai ini ke dokumen/commit.
- Tunnel memakai `ControlMaster` di `.local/devdb.sock`; `ControlPersist=600`
  sehingga perintah `ssh` berikutnya tidak perlu handshake ulang.

## 3. Batas (jangan dilewati)

- Hanya menyentuh DB dev dan role dev-nya. DB `cbs` (milik `cbs-core`) **tidak disentuh**.
  Nama DB dan role dev sudah **di-rename di server** menjadi `kran_dev` (D-039, 15 Okt 2026):
  `ALTER DATABASE` + `ALTER ROLE`, dijalankan sebagai superuser `qouver`. `.local/dev.env` sudah
  menunjuk ke sana; DB `cbs` milik sistem lama tidak disentuh.
- Tidak ada perubahan kuadlet/container/config/backup/hook di server.
- Tidak ada data nyata di DB dev; data uji selalu sintetis (AGENTS.md §3).

## 4. Provisioning awal (sekali, 2026-10-13)

Dijalankan sebagai `sachiel` di server, memakai `podman exec qouver-postgres`:

```sh
# role + database
psql -U qouver -c "CREATE ROLE kran_dev LOGIN"          # idempotent (cek pg_roles dulu)
psql -U qouver -c "ALTER ROLE kran_dev PASSWORD '<rahasia>'"
psql -U qouver -c "CREATE DATABASE kran_dev OWNER kran_dev"
# ekstensi (spec §9.1)
psql -U kran_dev -d kran_dev -c "CREATE EXTENSION pgcrypto; CREATE EXTENSION pg_trgm; CREATE EXTENSION btree_gist;"
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
KRAN_DEVDB_PERSIST=7200
```

`./task devdb up` idempotent (tunnel yang sudah jalan tidak dibuka dua kali).

Tunnel juga bisa mati karena **koneksi SSH putus**, bukan hanya karena idle (kejadian 16 Okt 2026:
`ControlPersist=7200` sudah terpasang dan keepalive aktif, tunnel tetap mati). Jadi: jalankan
`./task devdb status` sebelum gate panjang, dan bila di tengah gate muncul `Connection refused` atau
`server closed the connection unexpectedly`, **periksa tunnel lebih dulu** sebelum menuduh kode — lalu
ulangi gate-nya. Jangan melonggarkan test untuk melewatinya.

### Migrasi & status

```sh
./task dbtools validate   # tanpa DB: urutan + berkas + penjaga expand-only
./task dbtools migrate    # butuh KRAN_DATABASE_URL; idempotent
./task dbtools status     # daftar migrasi + deteksi berkas yang isinya berubah
```

Test integrasi `modules/platform/tests/itplatform.nim` **menghapus schema `platform`**
(termasuk isi `audit_log`) lalu menerapkan ulang migrasi. Jangan arahkan
`KRAN_DATABASE_URL` ke DB yang datanya berharga.

## Catatan operasional (15 Okt 2026)

`./task devdb up` sekarang membuktikan tunnel dengan **query nyata** ke DB (`select 1`), bukan
sekadar cek port/`ssh -O check`. Alasannya: tunnel yang SSH-nya sudah mati tetap menerima koneksi di
port lokal, sehingga gejalanya baru muncul sebagai `server closed the connection unexpectedly` di
tengah `./task test` (3× kejadian 14–15 Okt 2026). Bila probe gagal, `up` membuang master connection
yang tersisa lalu membuka tunnel baru, dan gagal keras kalau query tetap tidak bisa.

Koneksi juga memakai keepalive (`ServerAliveInterval=30`, `ServerAliveCountMax=3`, `TCPKeepAlive`)
supaya tidak diputus jaringan saat menganggur.

