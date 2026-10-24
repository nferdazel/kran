# AGENTS.md — repo kran

Kamu mengembangkan KRAN standar Indonesia (koperasi, BPR/BPRS, BMT). Sumber kebenaran:
`docs/spec/kran-prd-techspec.md` (PRD/TECHSPEC). Kalau kode dan spec bertentangan, JANGAN
diam-diam memilih; catat di `docs/DECISIONS.md` dan eskalasi (lihat §8).

## 1. Aturan emas (tidak boleh dilanggar)
1. Clean Architecture (domain → application → infrastructure/interface), modul hanya bicara
   lewat `api.nim` dan event. Ditegakkan `tools/archcheck`.
2. **Tidak ada nilai bisnis di kode.** Semua dari parameter DB (spec §10). Key param hanya via
   hasil `paramgen`. Magic number bisnis = gagal di `lint-nomagic`.
3. **Uang hanya lewat tipe `Money`.** Tidak ada float untuk uang/rate. Ledger immutable;
   koreksi = jurnal pembalik.
4. Semua teks UI lewat i18n (id + en). Tidak ada string hardcode di komponen.
5. a11y WCAG 2.2 AA + dark/light: komponen baru harus lolos axe di 2 tema, dan alur kritis
   bisa dipakai keyboard-only.
6. KISS & DRY pragmatis: jangan tambah dependensi/abstraksi tanpa ADR. Duplikasi kebetulan boleh;
   duplikasi aturan bisnis tidak.
7. Day-close (EOD/EOM/EOY) hanya lewat framework `daycloser` (task terdaftar, idempotent).
   Dilarang bikin batch/cron sendiri di modul.
8. Jangan mengarang fakta regulasi. Isi §4 spec bertanda V?/V! BELUM terverifikasi: boleh
   dijadikan struktur/parameter, tapi nilai/pasal pasti harus ditandai `NEEDS-COMPLIANCE-REVIEW`
   di kode/seed/docs dan dicatat di `docs/OPEN_ITEMS.md`.

## 2. Perintah standar (satu pintu)
`task check`   → format + lint + archcheck + lint-nomagic + paramgen --check + i18n check
`task check-fast` → seperti `check` tanpa `nim check` penuh (loop harian, D-077)
`task verify [filter]` → `check-fast` + openapi + build + test modul terpilih (loop harian)
`task test`    → unit + property + integration (Postgres ephemeral) + contract
`task e2e`     → Playwright (e2e + axe 2 tema + svelte-check); visual regression belum ada (O-022)
`task lint-web` → eslint (typescript-eslint + `svelte/*` non-a11y); butuh `pnpm install`
`task ci`      → semua di atas (harus hijau sebelum menyatakan task selesai; DoD tidak berubah).
Selama implementasi pakai `task verify <modul>`; `nim check` penuh di-shard paralel (D-077).
Kalau perintah ini belum ada, MEMBUATNYA adalah task pertama (Fase 0, T-001).

## 3. Git & rilis — PENTING
- Push ke `main` = DEPLOY ke produksi (webhook → deploy-vps.sh). Karena itu:
  **JANGAN PERNAH push/merge ke `main`.** Kerja di branch `feat/<id>-<slug>`; commit kecil;
  buka PR (atau tinggalkan branch siap-review). Merge ke main hanya oleh manusia.
- Jangan sentuh server/VPS, webhook, Caddy, secret, atau `ops/` produksi kecuali task
  eksplisit meminta menulis *file* di repo (bukan menjalankan di server).
- Jangan commit secret/ data nyata. Data uji selalu sintetis.
- Conventional commits; satu commit = satu perubahan logis.

## 4. Protokol loop per task (WAJIB)
Ambil task teratas berstatus `READY` dari `docs/BACKLOG.md`, lalu:
1. **Plan**: tulis rencana singkat di file task (`docs/tasks/T-xxx.md`): scope, file yang
   disentuh, bagian spec, kriteria selesai (dari Definition of Done §6).
2. **Test-first** bila memungkinkan (domain, Money, perhitungan: property + golden test).
3. **Implement** dalam langkah kecil; jalankan `task check` sering.
4. **Self-verify**: `task ci` hijau. Jangan klaim selesai tanpa output yang benar-benar dijalankan.
5. **Independent review**: panggil reviewer dengan konteks BERSIH (subagent/sesi baru) memakai
   prompt di `docs/agent/REVIEWER.md`. Reviewer hanya membaca diff + spec, bukan alasanmu.
6. **Fix**: perbaiki semua temuan `BLOCKER` dan `MAJOR`. `MINOR` boleh ditunda ke backlog
   (catat). Jangan berdebat dengan reviewer tanpa bukti (test/ referensi spec).
7. Ulangi 4–6 sampai reviewer menyatakan `APPROVE` (tanpa BLOCKER/MAJOR) dan `task ci` hijau.
   **Batas**: maksimal 5 putaran review per task. Lewat itu → STOP, tulis ringkasan
   masalah di `docs/ESCALATIONS.md`, tandai task `BLOCKED`, lanjut ke task independen lain.
8. **Commit + update state**: `docs/PROGRESS.md` (apa selesai, bukti, sisa), tandai task
   `DONE`, tambah task turunan ke backlog bila ditemukan.
9. Lanjut ke task `READY` berikutnya. Berhenti di akhir milestone (§7).

## 5. Disiplin anti-halusinasi & anti-"selesai palsu"
- Setiap klaim "sudah jalan" harus disertai perintah + ringkasan output.
- Dilarang melemahkan test/ lint/ gate agar hijau (menghapus test, `skip`, longgarkan
  threshold, menambah `nomagic:ok`/ ignore) tanpa entri di `docs/DECISIONS.md` + alasan,
  dan itu otomatis dieskalasi.
- Jangan "mengerjakan sebagian lalu menandai DONE". Sisa pekerjaan = task baru.
- Kalau ragu soal perilaku bisnis/regulasi: tulis asumsi di task + `OPEN_ITEMS.md`, pilih opsi
  paling konservatif/ paling aman, lanjutkan.
- Library Nim: cek ketersediaan & versi sebelum dipakai; dependensi baru butuh ADR singkat.

## 6. Definition of Done (task)
- [ ] Kode + test (unit/ property/ integration sesuai jenisnya) lulus; `task ci` hijau
- [ ] Batas arsitektur terjaga; tidak ada magic number bisnis; param baru terdaftar + seed + schema
- [ ] Uang via `Money`; tidak ada float
- [ ] Use case atomik; event via outbox; idempotency pada operasi finansial
- [ ] OpenAPI diperbarui + contract test lulus
- [ ] i18n id+en lengkap; a11y (axe 2 tema, keyboard) untuk UI
- [ ] Audit event & permission tepat; data sensitif ter-mask/ terenkripsi
- [ ] Migrasi aman (expand-only; contract terpisah)
- [ ] `MODULE.md` + docs diperbarui; requirement regulasi terkait di-tag (`@REG-xxx`)
- [ ] Reviewer: APPROVE

## 7. Milestone & berhenti
Milestone = Fase di spec §23. Setelah semua task fase `DONE`:
1. Jalankan `task ci` penuh + (bila ada) simulasi day-close + benchmark.
2. Tulis `docs/milestones/M<fase>-report.md`: yang selesai, bukti, gate, deviasi dari spec,
   open items, risiko, saran langkah berikut.
3. **STOP** dan tunggu manusia. Jangan mulai fase berikutnya sendiri.

## 8. STOP & eskalasi ke manusia (jangan lanjut menebak) jika:
- Butuh keputusan ADR terbuka (mis. ADR-002 HTTP server, ADR-013 mesin PDF) → lakukan spike
  singkat, tulis perbandingan + rekomendasi, lalu STOP untuk keputusan.
- Menyentuh area kritis dan hasilnya tidak bisa dibuktikan test: rumus bunga/akrual/PPAP/SHU/
  pajak, rekonsiliasi, enkripsi/ key management, authz, hash-chain audit.
  (Boleh diimplementasi, tapi WAJIB ditandai `HUMAN-REVIEW-REQUIRED` di PR.)
- Pasal/angka regulasi tidak pasti (§1.8).
- Perubahan yang butuh akses di luar repo (server, secret, registry, DNS).
- Spec ambigu/ kontradiktif, atau perlu menyimpang dari spec.
- Terdeteksi test/ gate yang tampak salah (bukan kodenya).
- Batas 5 putaran review tercapai, atau 3 kali gagal dengan penyebab sama.

## 9. Gaya kerja
Bahasa kode/ identifier: Inggris. Dokumentasi & komentar domain: Indonesia boleh.
Ringkas, konkret, tanpa janji berlebihan. Jangan refactor di luar scope task; catat saja.

