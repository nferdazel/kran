# PROGRESS — CBS

Log apa yang benar-benar selesai, dengan buktinya. Format: satu entri per task.

Aturan (AGENTS.md §5): klaim "sudah jalan" **wajib** disertai perintah + ringkasan output.
Tidak ada entri DONE di sini sebelum `./task ci` benar-benar dijalankan.

---

## 2026-10-13 — bootstrap sesi Fase 0

**Konteks**: repo masih kosong (belum ada commit; hanya `AGENTS.md` + `docs/spec/`).
Dikerjakan di branch `feat/fase0-fondasi` (tidak pernah push ke `main`).

**Keputusan awal** (detail di `docs/DECISIONS.md`):

- D-001 — satu pintu perintah = skrip POSIX `./task` (bukan Taskfile/just) → tanpa dependensi baru.
- D-002 — satu paket `cbs.nimble` untuk seluruh monorepo; direktori sumber lewat `-p:`.
- D-003 — dependensi Nim Fase 0: `db_connector` 0.1.0 + `yaml` 2.2.1 (nimYAML).
- D-004 — DB dev/integration di server (`cbs_dev`) via tunnel SSH; `CBS_DATABASE_URL` di `.local/dev.env`.

**Bukti provisioning DB dev** (dijalankan 2026-10-13):

```
$ ssh sachiel@43.133.148.191 'podman exec -i qouver-postgres psql -U qouver -Atc "select datname ..."'
cbs_dev|cbs_dev|btree_gist,pg_trgm,pgcrypto,plpgsql     <- role cbs_dev login, DB cbs_dev, ekstensi siap
$ psql "$CBS_DATABASE_URL" -Atc "select 'tunnel-ok'"
tunnel-ok
PostgreSQL 18.6 (Debian 18.6-1.pgdg13+2)
```

---

## 2026-10-13 — T-003 tooling gate (archcheck, lint-nomagic, paramgen)

**Rencana/scope**: `docs/tasks/T-003.md`. Tiga tool + test, menggantikan SKIP di `./task check`.

**Bukti `./task ci`** (satu-satunya klaim "hijau" yang saya buat; log penuh `.build/ci-t003.log`):

```
$ ./task ci
== format (nimpretty)             ok: 29 berkas
== lint (nim check)               ok: 30 berkas
== archcheck                      archcheck: tidak ada pelanggaran batas arsitektur
== lint-nomagic                   lint-nomagic: tidak ada magic number bisnis di domain/application
== paramgen --check               paramgen: sinkron (0 berkas seeds/params.yaml)
== i18n check                     -- SKIP: packages/i18n/messages belum ada (T-010)
== unit + property test           12 berkas test (kernel 9 + tools 3), [OK] 97 / [FAILED] 0
== integration test (Postgres)    -- SKIP: belum ada test integrasi (T-004)
== contract test                  -- SKIP: packages/contracts/openapi belum ada (T-008)
== e2e                            -- SKIP: apps/web/package.json belum ada (T-010)
== CI hijau                       (exit 0)
```

**Bukti gate benar-benar menolak** (probe sementara di repo, lalu dihapus):

```
$ cat > modules/lending/domain/tmp_probe.nim   # berisi import deposit/infrastructure/pg_repo + 91 + 0.05 + "Rp 1.000.000"
$ ./task nomagic
lint-nomagic: 3 temuan
  modules/lending/domain/tmp_probe.nim:4: angka 91 bukan konstanta teknis; pakai parameter DB
  modules/lending/domain/tmp_probe.nim:5: literal desimal dianggap nilai bisnis: 0.05
  modules/lending/domain/tmp_probe.nim:6: literal string bernilai bisnis: "Rp 1.000.000"   (exit 1)
$ ./task archcheck
archcheck: 1 pelanggaran
  modules/lending/domain/tmp_probe.nim:2: [C] modul hanya lewat api.nim modul lain, bukan internalnya: deposit/infrastructure/pg_repo   (exit 1)
```

**Keputusan desain** (rincian di `docs/tasks/T-003.md`):

- Definisi parameter (pack-independent, `packs/base`) dipisah dari nilai per segment pack
  (`packs/<pack>/generated/param_values.sql`) — menghindari FK ke definisi yang belum ada.
- Kode hasil generate tidak diformat ulang nimpretty (`fmt_files()` di `./task`) tetapi tetap
  di-`nim check`; tanpa itu `./task fmt` akan merusak `paramgen --check`.
- Tiga tool sengaja tidak saling import (klasifikasi lapisan diduplikasi ~12 baris) supaya satu
  gate tidak bisa menjatuhkan gate lain.
- `paramgen` menolak `type: duration` sampai ada tipe `Duration` di kernel (tidak menebak satuan).
- Semua seed SQL ditandai `NEEDS-COMPLIANCE-REVIEW` (spec §1.8).

**Batas jujur**: `lint-nomagic` deteksi string berbasis pola, bukan semantik; efektivitasnya
pada modul nyata baru terbukti setelah T-004/T-007 menambah `modules/*/domain`.

---

## 2026-10-13 — T-004 skeleton `platform` (pool, migrasi, outbox/inbox, audit hash-chain)

**Rencana/scope**: `docs/tasks/T-004.md`.

**Bukti `./task ci`** (log penuh `.build/ci-t004.log`, exit 0):

```
$ ./task ci
== format (nimpretty)             ok: 44 berkas
== lint (nim check)               ok: 45 berkas
== archcheck                      tidak ada pelanggaran batas arsitektur
== lint-nomagic                   tidak ada magic number bisnis di domain/application
== paramgen --check               sinkron
== unit + property test           15 berkas (kernel 9, platform-lib 2, tools 4)
== integration test (Postgres)    modules/platform/tests/itplatform.nim
                                  shared/platform-lib/tests/itpool.nim
== i18n / contract / e2e          SKIP (T-010, T-008 menunggu E-001, T-010)
== CI hijau                       (153 assertion lulus, 0 gagal)
```

**Bukti langsung terhadap DB dev (`cbs_dev` via tunnel)**:

```
$ ./task dbtools migrate
dbtools migrate: 3 diterapkan, 0 dilewati (sudah ada)     # pertama kali
$ ./task dbtools migrate
dbtools migrate: 0 diterapkan, 3 dilewati (sudah ada)     # idempotent
$ ./task dbtools status
      1  platform/0001_platform_schema  sudah
      2  platform/0002_platform_audit_log  sudah
      3  platform/0003_platform_outbox_inbox  sudah
dbtools status: 3/3 diterapkan
```

Test integrasi yang lulus (14 + 7 assertion, ringkas): migrasi idempotent; checksum drift
ditolak; migrasi gagal tidak tercatat & tabelnya tidak ada (atomik); outbox de-dup `dedup_key`;
klaim `FOR UPDATE SKIP LOCKED` (IN_FLIGHT tidak diklaim ulang, `attempts` naik); backoff menunda
klaim; dead-letter setelah `maxAttempts`; re-drive; inbox de-dup per konsumen; rantai audit
terverifikasi; perusakan payload → `row_hash_ok=false`; perusakan + hash dihitung ulang →
`link_ok=false` di baris berikutnya; UPDATE/DELETE/TRUNCATE ditolak; pool: batas tunggu,
`withTx` commit/rollback, koneksi bocor bertransaksi di-ROLLBACK.

**Keputusan** (rincian `docs/DECISIONS.md` D-005…D-007, `docs/tasks/T-004.md`):

- Skrip SQL multi-pernyataan lewat `PQexec` (dbtools), query aplikasi tetap lewat `db_connector`.
- Hash rantai audit dihitung di DB (trigger + pgcrypto), payload kanonik UTC/ISO.
- `CBS_DEVDB_PERSIST` supaya tunnel dev tidak mati di tengah sesi (kejadian nyata: tunnel
  menutup setelah 10 menit idle → `Connection refused`).

**Open items baru**: O-009 (anchor harian rantai hash), O-010 (pemisahan privilege append-only),
O-011 (pool: polling + peminjaman paralel belum diuji).

**Batas jujur**: peminjaman koneksi paralel antar-thread belum diuji di CI (single-thread);
`itplatform` menghapus schema `platform` (aman hanya untuk DB dev `cbs_dev`); `CBS_DATABASE_URL`
hanya bentuk URL tanpa `sslmode`.

---

## Catatan proses (jujur, 2026-10-13)

1. **Commit `01094a1` tercampur.** Commit untuk spike ADR-002 memakai `git add -A` sehingga
   ikut menyeret draf `shared/kernel/**` dan `docs/migration/cbs-core-inventory.md` yang saat
   itu belum selesai. Tidak ada yang hilang, tetapi commit itu tidak lagi "satu perubahan
   logis" (AGENTS.md §3). Tidak saya tulis ulang karena rewrite history butuh persetujuan
   pemilik — dicatat di sini sebagai deviasi. Commit-commit setelahnya kembali satu-topik.
2. **Tiga percobaan subagent gagal** (T-002, T-003, T-015) dengan error `invalid request`
   dari sisi penyedia setelah prompt panjang terkirim; hanya T-015 yang akhirnya selesai
   (percobaan kedua/ketiga). Akibatnya: T-002 sempat meninggalkan `propgen.nim` versi
   berbeda + `tprop_rate.nim` yang tidak kompilasi (`out` sebagai nama variabel, API harness
   tidak cocok). Berkas itu ditulis ulang dengan harness final; `propgen.nim` subagent
   tertimpa versi final. T-003 akhirnya **tidak** dikerjakan subagent dan menjadi tanggungan
   sesi ini.
3. **Reviewer independen** (AGENTS.md §4 butir 5) belum dijalankan per task; rencananya satu
   review batch di akhir milestone atas area kritis (hash-chain audit, param framework,
   uang/rate), karena biaya dan karena task sejauh ini masih scaffolding + kernel. Keputusan
   ini dicatat supaya tidak terlihat seperti kelalaian.

## Status task

| Task | Status | Bukti ||---|---|---|
| T-001 | DONE | `./task ci` hijau; commit `5964665` |
| T-002 | DONE | `./task test kernel` → 52 assertion lulus, 0 gagal; `./task check` ok (20 berkas); grep non-komentar `float` = bersih |
| T-014 | DONE (spike) | `docs/spikes/ADR-002-http-server.md`: Mummy 54.341 rps / Prologue 46.094 / asyncnet 18.824 (`hey -n 10000 -c 50`, laptop 2026-10-13); Mummy 0.4.8 tanpa API streaming (endpoint stream → 501); keputusan menunggu E-001 |
| T-015 | DONE | `docs/migration/cbs-core-inventory.md` (600 baris). Angka kunci diverifikasi ulang dari `cbs-core`: 699 berkas Go, 370 `*_test.go`, 173 migrasi, README menyebut BPR/BPRS (bukan koperasi). 4 klaim ditandai `(belum diverifikasi)` |
| T-004 | DONE | `./task ci` hijau (exit 0, `.build/ci-t004.log`): 153 assertion lulus. `./task dbtools migrate` 2× = idempotent; 14 test integrasi platform + 7 test integrasi pool lulus (hash-chain tamper terdeteksi, outbox de-dup, migrasi atomik) |
| T-003 | DONE | `./task ci` hijau (exit 0, log `.build/ci-t003.log`): 29 berkas terformat, 30 `nim check`, archcheck/lint-nomagic/paramgen sinkron, 97 assertion test lulus (12 berkas). Gate dibuktikan menolak lewat probe nyata (3 temuan magic + 1 pelanggaran rule C) |
