# OPEN ITEMS — CBS

Hal yang belum bisa ditutup sekarang, tapi jangan hilang. Setiap item punya pemilik
tindakan yang jelas.

| ID | Item | Kenapa terbuka | Tindakan yang dibutuhkan | Terkait |
|---|---|---|---|---|
| O-001 | Nilai/pasal regulasi §4 bertanda `V?`/`V!` **belum terverifikasi** | Butuh compliance officer/konsultan (spec §4.5, §26.2 #3) | Validasi register §4 sebelum jadi requirement final; apa pun yang ditanam di kode/seed **wajib** bertanda `NEEDS-COMPLIANCE-REVIEW` | spec §1.8, §4 |
| O-002 | DB non-prod di server produksi ikut ter-backup harian | Temuan P1 audit server 2026-10-13 (§1 #2): 7 `cbs_verify*` + `fond_nim` + `skyward_test`. Kini bertambah satu: `cbs_dev` | Tambahkan filter di `backup-postgres.sh` (`datname NOT LIKE '%\_verify%' AND NOT LIKE '%\_test%' AND NOT LIKE '%\_dev%'`) + drop DB verify lama — **di luar repo, butuh akses server** | docs/DECISIONS.md D-004 |
| O-003 | Apakah `cbs-core` berisi data/pengguna nyata? | Menentukan perlu-tidaknya ETL + shadow run saat cutover (§21.9 tahap 3–4) | Inventaris + konfirmasi pemilik | T-015, spec §26.2 #1 |
| O-004 | Belum ada target volume & calon pilot | Menentukan budget performa (EOD <30 menit) & prioritas pack | Tetapkan setelah Fase 0 (spec §23) | spec §26.2 #2/#4 |
| O-005 | ADR-002 (HTTP server Nim) masih terbuka | Butuh benchmark + keputusan manusia; memblokir T-008/T-009/T-012 | Spike T-014 → keputusan pemilik | T-014, spec §25 |
| O-006 | Kunci enkripsi field (KEK) belum ada tempat aman | Server tanpa secret manager (audit 2026-10-13 §21.8) | Minimal KEK di file terpisah (600) di luar backup DB; rencanakan `age`/`sops` | spec §18.2, §21.8 |
| O-007 | Restore test Postgres belum pernah dilakukan | Gate go-live (§21.8) | Jadwalkan restore test bulanan + catat hasilnya di `docs/runbooks/` | spec §21.8, §22 |
| O-008 | Buffer/`deploy.log` & hardening lain di server | Di luar repo | Tindak lanjut terpisah dari audit server 2026-10-13 §10 | vps repo |
| O-009 | Rantai hash `platform.audit_log` belum punya *anchor* harian | Rantai mendeteksi perusakan **tanpa** rekalkulasi; penyerang dengan hak tulis penuh bisa menulis ulang seluruh ekor rantai (spec §18.2 minta anchor dicatat di tempat terpisah) | Task baru: simpan hash terakhir per hari (tabel/berkas terpisah + verifikasi di day-close) | T-004, spec §18.2, §11 |
| O-010 | Append-only audit masih bersandar pada trigger, bukan pada pemisahan privilege | Role aplikasi saat ini = pemilik tabel (dev). `REVOKE UPDATE/DELETE` baru bermakna setelah role produksi dipisah (owner migrasi vs role aplikasi) | Saat menyiapkan deployment (T-013/T-006): buat role aplikasi tanpa UPDATE/DELETE + uji | T-004, spec §9.1(3), §18.2 |
| O-011 | Pool DB menunggu koneksi dengan polling 2 ms; peminjaman paralel antar-thread belum diuji di CI | `std/locks` tidak menyediakan `wait` bertimeout; test integrasi pool berjalan single-thread | Stress test bersamaan + (bila perlu) antrean bertimeout; ukur sebelum optimasi | T-004, spec §12.1 |
