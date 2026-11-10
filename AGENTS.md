# AGENTS.md - repo kran

Kamu mengembangkan KRAN untuk **KSP (koperasi simpan pinjam)** sebagai vertical slice pertama.
Sumber arah kerja: `docs/ROADMAP.md` dan `docs/BACKLOG.md`. Sumber kebenaran produk:
`docs/spec/kran-prd-techspec.md`. Kalau kode dan spec bertentangan, JANGAN diam-diam memilih;
catat di `docs/DECISIONS.md` dan eskalasi (§8).

## 1. Aturan emas (tidak boleh dilanggar)
1. **Tidak ada nilai bisnis di kode.** Semua dari parameter DB. Key param hanya via hasil
   `paramgen`. Magic number bisnis = gagal di `lint-nomagic`.
2. **Uang hanya lewat tipe `Money`.** Tidak ada float untuk uang/rate. Ledger immutable;
   koreksi = jurnal pembalik, dan hanya untuk jurnal yang kepemilikannya jelas.
3. **Batas modul.** Modul hanya bicara lewat `api.nim` dan event. Setiap modul baru menaruh use
   case di `application/` sejak commit pertama; modul lama diekstrak saat disentuh (R-18/R-24).
   `apps/api/src` diperiksa archcheck setelah P0 dan baseline-nya hanya boleh menyusut.
4. Semua teks UI lewat i18n (id + en). Tidak ada string hardcode di komponen.
5. a11y WCAG 2.2 AA + dark/light: komponen baru harus lolos axe di 2 tema, dan alur kritis bisa
   dipakai keyboard-only.
6. KISS & DRY pragmatis: jangan tambah dependensi/abstraksi tanpa ADR.
7. Day-close (EOD/EOM/EOY) hanya lewat framework `daycloser` (task terdaftar, idempotent).
   Dilarang membuat batch/cron sendiri di modul.
8. Jangan mengarang fakta regulasi. Nilai/pasal yang belum terverifikasi harus ditandai
   `NEEDS-COMPLIANCE-REVIEW` di kode/seed/docs dan dicatat di `docs/OPEN_ITEMS.md`.
9. **Jangan melemahkan gate, test, threshold, baseline atau lint** untuk membuat sesuatu hijau.
   Baseline hanya menyusut. Pengecualian butuh `D-xxx` baru yang disetujui pemilik.

## 2. Perintah standar (satu pintu)
`./task check`      → format + lint + archcheck + lint-nomagic + paramgen --check + i18n check
`./task check-fast` → seperti `check` tanpa `nim check` penuh (loop harian)
`./task verify [filter]` → `check-fast` + openapi + build + test modul terpilih
`./task test`       → unit + property + integration (Postgres ephemeral) + contract
`./task e2e`        → Playwright (e2e + axe 2 tema + svelte-check + baseline visual)
`./task lint-web`   → eslint (butuh `pnpm install`)
`./task ci-fast`    → `check` + openapi + `lint-web` + test + (`svelte-check` + `vitest` web setelah P0)
`./task ci`         → `ci-fast` + e2e; harus hijau sebelum rilis/merge
`./task version`    → cetak `VERSION` (satu sumber untuk API, web, `kran.nimble`, `package.json`)
`./task release`    → bump + CHANGELOG + gate + commit + tag anotasi (D-178, D-194)
`python3 tools/docsgen/docsgen.py --check` → deteksi drift `PARAMETERS.md`/`SCHEMA.md`
Selama implementasi pakai `verify <modul>`/`ci-fast`; e2e menumpang di `ci`/`release`.

## 3. Git & rilis - PENTING
- Push ke `main` = DEPLOY ke produksi (webhook → `deploy-vps.sh`). Push **hanya** lewat
  `./task release`, tidak pernah `git push` manual ke `main`.
- Repo solo: commit boleh di `main` (D-198). Perubahan besar (skema, uang, docs rebuild) kerjakan
  di branch dan minta review diff sebelum merge.
- Jangan sentuh server/VPS, webhook, Caddy, secret, atau `ops/` produksi kecuali task meminta
  menulis *file* di repo.
- Jangan commit secret atau data nyata. Data uji selalu sintetis dan diberi label.
- Conventional commits; satu commit = satu perubahan logis.
- Tag `vX.Y.Z` adalah penanda, bukan pemicu deploy (D-178, `docs/RELEASE.md`).

## 4. Protokol loop per task (WAJIB)
Ambil task `READY` teratas dari `docs/BACKLOG.md`. Baris baru berstatus `READY` hanya setelah file
`docs/tasks/T-<id>.md` ada dan semua item DoR terisi (R-32); plan table saja tidak cukup. Lalu:
1. **DoR**: lengkapi `docs/tasks/T-<id>.md` dari `docs/tasks/_TEMPLATE.md` - anchor bukti, file,
   key parameter, bentuk migrasi, test, rollback, kelas risiko. Task tanpa DoR kembali ke backlog.
2. **Test-first** bila memungkinkan (domoney, perhitungan: property + golden test).
3. **Implement** kecil-kecil; jalankan `./task check-fast` sering.
4. **Self-verify**: gate yang disebut task benar-benar dijalankan; `./task ci-fast` hijau.
   Jangan klaim selesai tanpa output nyata.
5. **Review** sesuai R-25 dan `docs/agent/REVIEWER.md`. Nilai antrean `full` (kelas konkret
   `money`, `schema`, `authz`, atau `audit`) wajib reviewer konteks bersih, maksimal
   **2 putaran**; nilai `standard` (kelas konkret `general`) cukup self-review + gate. Header
   task menyebut kelas konkretnya. Perbaiki semua BLOCKER/MAJOR; MINOR dicatat sebagai open item.
6. **Evidence block** di file task: perintah, ringkasan output, commit range, hasil migrasi,
   pengecekan manual untuk UI, status capability.
7. **Commit**, tandai `DONE`, perbarui `docs/CAPABILITIES.md` bila kapabilitas berubah.
8. Lanjut task berikutnya. Berhenti di akhir fase (§7).

## 5. Disiplin anti-halusinasi & anti-"selesai palsu"
- Setiap klaim "sudah jalan" disertai perintah + ringkasan output.
- Dilarang melemahkan test/lint/gate agar hijau (hapus test, `skip`, longgarkan threshold,
  tambah `nomagic:ok`/ignore). Pengecualian butuh `D-xxx` dan dieskalasi.
- Jangan mengerjakan sebagian lalu menandai DONE. Sisa pekerjaan = task baru.
- Klaim kapabilitas harus menunjuk test yang akan gagal bila kapabilitas itu rusak.
- Exit fase gagal bila pemeriksaan yang disebut dilewati: tooling tidak ada, database tidak ada,
  test nol, atau axe tidak dijalankan adalah gagal, bukan lulus (R-33).
- Kalau ragu soal perilaku bisnis/regulasi: tulis asumsi di task + `OPEN_ITEMS.md`, pilih opsi
  paling konservatif, lanjutkan.
- Library baru: cek versi dan kebutuhan; dependensi baru butuh ADR singkat.

## 6. Definition of Done (ringkas)
- [ ] DoR terpenuhi; acceptance di file task bisa gagal tanpa perubahan ini
- [ ] Gate yang disebut dijalankan; `./task check-fast` (dan `ci-fast` untuk backend) hijau
- [ ] Uang via `Money`; tidak ada float; invariant ledger terjaga
- [ ] Migrasi expand-only (contract terpisah) dan aman dijalankan ulang
- [ ] OpenAPI + contract test; i18n id+en; a11y (axe 2 tema, keyboard)
- [ ] Audit event & permission tepat; data sensitif ter-mask/terenkripsi
- [ ] `MODULE.md`/docs terkait diperbarui; tag `REG-xxx` bila relevan
- [ ] Evidence block terisi; review (bila wajib) APPROVE
- [ ] `CAPABILITIES.md` mencerminkan status sebenarnya

## 7. Fase & berhenti
Fase = P0-P8 di `docs/ROADMAP.md`, bukan nomor Fase lama. Setelah semua task satu fase `DONE`:
1. Jalankan gate fase (`./task ci-fast`, dan `./task ci` bila fase menyentuh UI/e2e).
2. Buktikan exit criterion fase dengan output, bukan prosa.
3. Perbarui `docs/history/PHASES.md` bila fase historis ditutup.
4. **STOP** dan tunggu manusia; jangan mulai fase berikutnya sendiri.

## 8. STOP & eskalasi ke manusia (jangan menebak) jika:
- Butuh keputusan ADR terbuka → spike singkat, tulis perbandingan + rekomendasi, lalu STOP.
- Menyentuh area kritis yang tidak bisa dibuktikan test: bunga/akrual/PPAP/SHU/pajak,
  rekonsiliasi, enkripsi/key management, authz, hash-chain audit.
  Boleh diimplementasi, tapi WAJIB ditandai `HUMAN-REVIEW-REQUIRED`.
- Pasal/angka regulasi tidak pasti, atau nilai belum terverifikasi.
- Perubahan butuh akses di luar repo (server, secret, registry, DNS).
- Spec ambigu/kontradiktif, atau perlu menyimpang dari spec.
- Terdeteksi test/gate yang tampak salah (bukan kodenya).
- Review putaran kedua masih menemukan BLOCKER, atau 3 kali gagal dengan penyebab sama.

## 9. Gaya kerja
- Kode, identifier, komentar kode, commit: **Inggris**.
- Dokumentasi hidup (`docs/**`) dan dokumen perencanaan: **Inggris** (R-11).
- Percakapan dengan pemilik: **Indonesia**.
- `AGENTS.md` ini tetap Indonesia karena dibaca manusia dan agen di repo ini.
- Ringkas, konkret, tanpa janji berlebihan. Jangan refactor di luar scope task; catat saja.
