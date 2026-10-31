# Prompt interaktif untuk 17 open item

Cara pakai: buka sesi agen baru di repo ini, tempel **satu** blok di bawah. Setiap blok memerintahkan
agen untuk bertanya dulu (satu pertanyaan per giliran, dengan opsi + rekomendasi), baru menulis
keputusan, baru menulis kode. Jangan menempel beberapa blok sekaligus kecuali memakai blok
"SEMUA SEKALIGUS" di bagian akhir.

Aturan yang sudah tertanam di setiap blok: jangan mengarang angka/pasal regulasi (tandai
`NEEDS-COMPLIANCE-REVIEW`), jangan melemahkan test/gate, jangan push ke `main` tanpa izin eksplisit
di sesi itu, dan setiap keputusan dicatat di `docs/DECISIONS.md` + `docs/OPEN_ITEMS.md`.

Urutan yang kusarankan (risiko naik): O-067 → O-044 → O-087 → O-093 → O-022 → O-026 → O-028 →
O-053 → O-064 → O-070 → O-075 → O-100 → O-114 → O-071 → O-024 → O-041 → O-008.

---

## O-067 — Penerus `effectiveTo` harus satu scope

```
Repo: /Users/sachiel/Projects/cbs. Bahasa dokumen: Indonesia; identifier kode: Inggris.
Tugas: selesaikan O-067 (penerus `effectiveTo` wajib satu (key, scope), lebih ketat daripada resolusi
parameter yang jatuh dari BRANCH ke GLOBAL).

Baca dulu: docs/OPEN_ITEMS.md baris O-067, docs/DECISIONS.md D-056, modules/platform/... fungsi
`effectiveToGapProblem` dan test-nya (cari dengan ripgrep), docs/spec/kran-prd-techspec.md §10.6.

Jangan menulis kode dulu. Tanyakan satu per satu (tunggu jawabanku setiap kali):
1. Pilih: (a) longgarkan pemeriksaan menjadi "ada baris yang berlaku pada `effectiveTo` di scope mana
   pun yang tercakup resolusi scope itu" — rekomendasiku, karena pengajuan sekarang bisa ditolak
   padahal tanggalnya tercakup nilai lain; atau (b) terima sebagai batas di ACCEPTED-LIMITS.
2. Kalau (a): apakah penutupan oleh nilai GLOBAL boleh menutup BRANCH, dan sebaliknya TIDAK (resolusi
   hanya jatuh ke atas)? Sebutkan arah yang kamu maksud.
3. Kalau (a): pesan 400 `effective_to_without_successor` perlu diubah? Kalau ya, kunci i18n id+en baru
   atau pakai yang ada?

Setelah kujawab: tulis keputusan di docs/DECISIONS.md (D-xxx baru), rencana di docs/tasks/T-xxx.md,
lalu implementasi + test yang membuktikan kedua arah (BRANCH ditutup GLOBAL boleh; GLOBAL tidak
ditutup BRANCH). Jalankan `./task test <suite platform>`, `./task check-fast`. Jangan push main.
```

---

## O-044 — Nilai calon dipakai tanpa memeriksa visibilitas scope

```
Repo: /Users/sachiel/Projects/cbs. Bahasa dokumen: Indonesia; identifier kode: Inggris.
Tugas: selesaikan O-044 (kandidat parameter ber-scope INSTITUTION:<id>/BRANCH:<id> tetap bisa menolak
perubahan walau baris itu tidak dibaca aplikasi).

Baca: docs/OPEN_ITEMS.md O-044 (termasuk catatan T-036 dan D-041), docs/DECISIONS.md D-029/D-041,
kode penilaian kandidat (ripgrep `sessionPolicyCandidateProblem` dan pemanggilnya), test T-036.

Jangan menulis kode dulu. Tanyakan satu per satu:
1. Pilih arah: (a) penilaian hanya memakai baris yang **terlihat** aplikasi (scope_id NULL + scope
   yang dibaca `institutionScope()`), atau (b) batasi pengajuan kebijakan sesi ke scope itu saja.
   Rekomendasiku (a) karena menjaga perilaku login sebagai sumber kebenaran.
2. Kalau (a): baris tak terlihat yang sudah ACTIVE — dilewati diam-diam atau dicatat di audit supaya
   operator tahu ada nilai yang tidak dipakai?
3. Perlu migrasi/seed? (harusnya tidak).

Setelah kujawab: D-xxx + docs/tasks/T-xxx.md, implementasi, test: kandidat INSTITUTION ber-id konkret
tidak lagi memblokir; kandidat yang terlihat tetap memblokir; kandidat BRANCH lain tidak memblokir
cabang ini. `./task check-fast` + suite terkait. Jangan push main.
```

---

## O-087 — Batas schema untuk nilai parameter `json`

```
Repo: /Users/sachiel/Projects/cbs. Bahasa dokumen: Indonesia; identifier kode: Inggris.
Tugas: selesaikan O-087 (`pvtJson` hanya dibatasi 16 KiB; batas schema dan batas desimal pecahan
ditolak fail-closed).

Baca: docs/OPEN_ITEMS.md O-087, tools/dbtools atau modules/platform tempat `pvtJson` divalidasi
(ripgrep `pvtJson`, `validateAgainstSchema`), dan definisi schema parameter di
packs/base/seeds atau modules/*/seeds.

Jangan menulis kode dulu. Tanyakan:
1. Apakah validasi schema JSON penuh diperlukan sekarang, atau cukup batas kedalaman + daftar tipe
   yang diizinkan? Rekomendasiku: batas kedalaman + larangan tipe yang tidak dipahami konsumen
   (lebih kecil risikonya daripada menulis validator schema penuh).
2. Batas desimal pecahan: implementasi perbandingan desimal (tanpa float) atau tetap tolak dengan
   pesan yang jelas? Rekomendasiku tetap tolak + dokumentasikan, karena belum ada parameter pecahan
   di seed pilot.
3. Kalau validasi ditambah: tolak saat submit, saat approve, atau keduanya? (rekomendasi: keduanya,
   pola `sessionPolicyCandidateProblem`).

Setelah kujawab: D-xxx, task file, implementasi + test (nilai dalam, kedalaman melebihi batas,
pecahan `minimum`/`maximum`, nilai sah tetap lolos). `./task check-fast` + suite parameter. Jangan
push main.
```

---

## O-093 — PII di `platform.idempotency_key.response_body`

```
Repo: /Users/sachiel/Projects/cbs. Bahasa dokumen: Indonesia; identifier kode: Inggris.
Tugas: selesaikan O-093 (response_body idempotency menyimpan respons sukses apa adanya, termasuk PII).

Baca: docs/OPEN_ITEMS.md O-093, docs/DECISIONS.md D-098 dan D-118, migrasi tabel idempotency, dan
endpoint yang menyimpan respons (ripgrep `response_body`).

Jangan menulis kode dulu. Tanyakan satu per satu:
1. Pilih: (a) retensi berparameter + pembersihan berkala (paling murah, tidak mengubah replay),
   (b) enkripsi kolom (butuh kunci + migrasi data), atau (c) field allowlist per endpoint (paling
   aman, paling rapuh karena replay harus identik). Rekomendasiku: (a) sekarang + catat (c) sebagai
   arah jangka panjang.
2. Kalau (a): berapa hari retensi dan dari mana angkanya? Jangan mengarang — usulkan sebagai
   parameter DB `platform.idempotency.retention_days` dan minta angka dariku.
3. Siapa yang menjalankan pembersihan: task day-close (modul mana) atau `ctl`? Rekomendasi: task
   harian non-kritis supaya kegagalan tidak menahan tutup buku.
4. Perlu audit/penghitung baris yang dibersihkan?

Setelah kujawab: D-xxx, migrasi parameter (expand-only), task day-close + test (baris lama terhapus,
baris baru tidak, replay masih jalan sebelum retensi), docs/ACCEPTED-LIMITS bila ada sisa.
`./task check-fast` + suite dayclose/idempotency. Jangan push main.
```

---

## O-022 — Visual regression test

```
Repo: /Users/sachiel/Projects/cbs. Bahasa dokumen: Indonesia; identifier kode: Inggris.
Tugas: selesaikan O-022 (belum ada visual regression; baseline macOS vs runner Linux berbeda).

Baca: docs/OPEN_ITEMS.md O-022, docs/spec/kran-prd-techspec.md §15.8/§17.2, apps/web/playwright.config.ts,
.github/workflows/ci.yml, docs/ACCEPTED-LIMITS.md.

Jangan menulis kode dulu. Tanyakan:
1. Baseline dibuat **di runner Linux** dan di-commit (rekomendasiku), atau gate hanya informasional
   (artifact, tidak memblokir)?
2. Layar mana yang masuk gelombang pertama? Rekomendasi: 3 layar dengan risiko visual tertinggi
   (`/app/ledger`, `/app/teller`, `/app/password`) × 2 tema, locale id saja.
3. Ambang diff: 0 (ketat) atau toleransi kecil? Rekomendasi: `maxDiffPixelRatio` kecil dan
   `animations: "disabled"`.
4. Font: apakah runner CI punya IBM Plex Sans yang sama? Kalau tidak, baseline di dalam container
   yang sama dengan runner (bukan macOS). Sebutkan cara yang kamu pilih.

Setelah kujawab: job CI baru dengan `timeout-minutes: 15` + cache Playwright, generate baseline di
runner, commit baseline, gate memblokir, dan dokumentasi cara memperbarui baseline. Jangan
menjalankan job di repo tanpa izin push.
```

---

## O-026 — `schemathesis` untuk contract test

```
Repo: /Users/sachiel/Projects/cbs. Bahasa dokumen: Indonesia; identifier kode: Inggris.
Tugas: putuskan O-026 (spec §20 menyebut `schemathesis`; sekarang validator sendiri di tools/openapi).

Baca: docs/OPEN_ITEMS.md O-026, tools/openapi (kemampuan validator saat ini), .github/workflows/ci.yml,
docs/spec/kran-prd-techspec.md §20.

Jangan menulis kode dulu. Tanyakan:
1. Pilih: (a) tambah job CI Python + server hidup yang menjalankan schemathesis, (b) tetap validator
   sendiri + catat alasan di ACCEPTED-LIMITS, (c) jalan manual di mesin developer saja.
   Rekomendasiku (b) sampai ada konsumen API eksternal — biayanya (Python + server + flakiness)
   belum sepadan; sebutkan bila kamu tidak setuju dan alasannya.
2. Kalau (a): cakupan endpoint mana dan berapa lama budget job? (harus ≤15 menit).

Setelah kujawab: kalau (b), tulis keputusan + alasan di DECISIONS/ACCEPTED-LIMITS (tanpa kode).
Kalau (a), buat job dengan cache pip + timeout + mode read-only (jangan biarkan schemathesis menulis
data produksi/ dev bersama).
```

---

## O-028 — Kuota antrean realtime

```
Repo: /Users/sachiel/Projects/cbs. Bahasa dokumen: Indonesia; identifier kode: Inggris.
Tugas: selesaikan O-028 (tidak ada kuota antrean keluar per koneksi realtime).

Baca: docs/OPEN_ITEMS.md O-028, modul realtime (ripgrep `topicsAllowedFor`, hub/pump), D-024/D-062,
docs/spec/kran-prd-techspec.md §19.2.

Jangan menulis kode dulu. Tanyakan:
1. Apakah kita ukur dulu di beban nyata (rekomendasiku) atau langsung pasang kuota? Kalau ukur:
   metrik apa yang dicatat dan di mana (log? endpoint?).
2. Kalau kuota: angka awalnya dari mana? Jangan mengarang — usulkan sebagai parameter DB
   (mis. `platform.realtime.queue_limit`) dan minta angkanya.
3. Perilaku saat kuota terlampaui: putus + klien resync lewat resume token, atau putus dengan kode
   alasan tertentu? Rekomendasi: putus + alasan `queue_overflow`, klien resync.
4. Apakah perlu test integrasi dua koneksi (lambat vs cepat)?

Setelah kujawab: D-xxx, parameter + migrasi, implementasi di pump, test, dokumentasi operator.
`./task check-fast` + suite realtime. Jangan push main.
```

---

## O-053 — Terjemahan `role.*` / `perm.*`

```
Repo: /Users/sachiel/Projects/cbs. Bahasa dokumen: Indonesia; identifier kode: Inggris.
Tugas: selesaikan O-053 (name_key/description_key role & izin belum ada di katalog i18n).

Baca: docs/OPEN_ITEMS.md O-053, modules/platform/migrations/0008_platform_rbac_catalogue.sql,
packs/base/seed, packages/i18n/messages/{id,en}.json, tools/i18ncheck (aturan pemakaian kunci).

Jangan menulis kode dulu. Tanyakan:
1. Apakah layar administrasi peran akan dibuat dalam waktu dekat? Kalau tidak, rekomendasiku: tunda
   (kunci tanpa pemakaian akan ditolak/berbunga di i18ncheck).
2. Kalau ya: role & izin mana yang masuk gelombang pertama, dan siapa yang menyetujui teksnya?
3. Apakah `name_key` tetap disimpan di DB (rekomendasi) atau diganti teks?

Setelah kujawab: kalau tunda, perbarui O-053 dengan pemicu yang jelas. Kalau ya, tambahkan kunci
id+en + pemakaian di layar + test. `./task check-fast` (i18ncheck) + `./task lint-web`.
```

---

## O-064 — Penanda "akhiri nilai parameter"

```
Repo: /Users/sachiel/Projects/cbs. Bahasa dokumen: Indonesia; identifier kode: Inggris.
Tugas: selesaikan O-064 (tidak ada cara mengakhiri nilai parameter tanpa penerus).

Baca: docs/OPEN_ITEMS.md O-064, D-046 butir 8, D-056 butir 5, alur submit/approve parameter,
`docs/spec/kran-prd-techspec.md` §10.

Jangan menulis kode dulu. Tanyakan:
1. Apakah kebutuhan ini nyata sekarang? Kalau tidak, rekomendasiku tunda + catat pemicunya.
2. Kalau ya: bentuk penandanya — field khusus di pengajuan (mis. `endAt`), atau baris "tanpa nilai"
   yang disetujui? Rekomendasi: field `endAt` + izin khusus + audit, karena tidak mengubah model
   nilai.
3. Siapa yang boleh mengakhiri: pembuat + penyetuju (maker-checker) atau hanya admin?
4. Bagaimana pembaca yang meminta tanggal sesudah `endAt`? Rekomendasi: `ParamNotFound` (fail-closed),
   bukan nilai terakhir yang diulang diam-diam.

Setelah kujawab: D-xxx, kontrak OpenAPI, migrasi (expand), handler + UI, test (akhiri lalu baca
sesudahnya = 404/ParamNotFound; sebelum = nilai lama). `./task check-fast` + `./task openapi`.
```

---

## O-070 — Penyaringan `param.changed` per cabang

```
Repo: /Users/sachiel/Projects/cbs. Bahasa dokumen: Indonesia; identifier kode: Inggris.
Tugas: selesaikan O-070 (topik param.changed hanya untuk izin institusi; pengguna ber-izin cabang
tidak menerima apa pun).

Baca: docs/OPEN_ITEMS.md O-070, kode realtime (`topicsAllowedFor`, pump, resume token), D-024/D-062,
test realtime yang ada.

Jangan menulis kode dulu. Tanyakan:
1. Semantik yang diinginkan: pelanggan cabang A menerima perubahan parameter yang **berlaku untuk
   cabang A** (termasuk GLOBAL/INSTITUTION), atau hanya perubahan ber-scope cabang A?
   Rekomendasiku yang pertama, karena itu yang memengaruhi perilakunya.
2. Apakah pelanggan tanpa izin cabang (institusi) menerima semua? (rekomendasi: ya)
3. Perubahan parameter yang tidak terlihat sama sekali: dikirim atau disaring? (rekomendasi: disaring)

Setelah kujawab: D-xxx, implementasi filter di titik kirim, test dua klien beda cabang + satu klien
institusi, dokumentasi. `./task check-fast` + suite realtime. Jangan push main.
```

---

## O-075 — Akun kontra

```
Repo: /Users/sachiel/Projects/cbs. Bahasa dokumen: Indonesia; identifier kode: Inggris.
Tugas: putuskan O-075 (akun kontra belum dimodelkan; D-106 menunda ke Fase 2 yang selesai tanpa itu).

Baca: docs/OPEN_ITEMS.md O-075, D-106, D-070, REG-011 di docs/spec (bagian COA), modul ledger
(domain/coa, report), dan kebutuhan pilot (docs/ACCEPTED-LIMITS, docs/milestones).

Jangan menulis kode dulu. Tanyakan:
1. Apakah pilot butuh CKPN/akumulasi penyusutan dalam 3 bulan? Kalau tidak, rekomendasiku: tunda,
   perbarui O-075 dengan pemicu.
2. Kalau ya: model — kolom `contra_of`/penanda `contra`, atau `normal_side` eksplisit per akun?
   Rekomendasi: penanda `contra` + `normal_side` tetap diturunkan, supaya laporan tidak menebak.
3. REG-011: angka/pasal belum terverifikasi — teks/seed harus `NEEDS-COMPLIANCE-REVIEW`. Siapa yang
   akan memverifikasi sebelum produksi?

Setelah kujawab: kalau tunda, dokumentasi saja. Kalau ya, D-xxx + migrasi expand + domain + laporan
+ property test neraca (aset − kontra tetap seimbang).
```

---

## O-100 — Iuran & klasifikasi ekuitas simpanan pokok/wajib

```
Repo: /Users/sachiel/Projects/cbs. Bahasa dokumen: Indonesia; identifier kode: Inggris.
Tugas: selesaikan O-100 (aturan iuran + perlakuan ekuitas/liabilitas simpanan pokok/wajib belum final).

Baca: docs/OPEN_ITEMS.md O-100, docs/DECISIONS.md D-128, T-111, COA `301.1`/`301.2`, REG-101 di
docs/spec, docs/ACCEPTED-LIMITS.

Ini keputusan akuntansi/regulasi: jangan mengarang. Tanyakan:
1. Siapa accounting owner yang memutuskan? (nama/peran)
2. Simpanan pokok/wajib disajikan sebagai ekuitas atau liabilitas untuk pilot ini, dan dasar
   rujukannya apa? (jangan menebak pasal)
3. Nominal + kadens iuran: parameter atau di luar sistem?
4. Perlakuan keluar anggota (refund/ forfeit) — ada atau ditunda?

Setelah kujawab: tulis keputusan + rujukan di DECISIONS (tandai `NEEDS-COMPLIANCE-REVIEW` bila
pasal belum diverifikasi), perbarui COA/seed bila perlu, dan ubah kode hanya bila keputusan sudah
tegas. Jangan mengubah perilaku ekuitas tanpa jawaban.
```

---

## O-114 — Penutupan otomatis rekening dormant

```
Repo: /Users/sachiel/Projects/cbs. Bahasa dokumen: Indonesia; identifier kode: Inggris.
Tugas: selesaikan O-114 (spec §11.6 menuntut deteksi dormant/tutup otomatis; sekarang hanya menandai).

Baca: docs/OPEN_ITEMS.md O-114, D-157, task `deposit.dormant` + `dormant_repo`, docs/spec §11.6,
ACCEPTED-LIMITS.

Jangan menulis kode dulu. Tanyakan:
1. Apakah penutupan otomatis boleh hanya untuk rekening **bersaldo nol** pada fase pertama?
   Rekomendasiku ya — tidak menyentuh dana anggota, jadi tidak butuh pemberitahuan/hak saldo.
2. Kalau saldo > 0: ditunda sampai ada aturan pemberitahuan + hak anggota? (rekomendasi: ya)
3. Dari mana menghitung "cukup lama dormant"? Kita tidak punya `dormant_since`; usulkan parameter
   tambahan `deposit.dormant_close.after_months` (angka dariku), dihitung dari aktivitas terakhir.
4. Apakah penutupan menulis audit (pola `deposit.dormant.chunk`)?

Setelah kujawab: D-xxx, migrasi parameter, task `deposit.dormant_close` (non-kritis? rekomendasi:
non-kritis sama seperti dormant), test: saldo 0 → CLOSED + audit; saldo > 0 → tidak disentuh;
rekening aktif → tidak disentuh. `./task check-fast` + `itdaycloser_deposit`.
```

---

## O-071 — MFA diminta saat login + pemulihan

```
Repo: /Users/sachiel/Projects/cbs. Bahasa dokumen: Indonesia; identifier kode: Inggris.
Tugas: rencanakan O-071 (faktor MFA terdaftar tidak pernah diminta; tidak ada pemulihan/penonaktifan).

Baca: docs/OPEN_ITEMS.md O-071, D-046 butir 9, D-063, modul MFA (`handlers_mfa`, `auth_service`),
tabel MFA, parameter `platform.security.mfa.enabled`.

Jangan menulis kode dulu. Ini mengubah jalur masuk; tanyakan:
1. Lingkup fase ini: (a) tantangan kode setelah kata sandi benar + kode pemulihan sekali pakai,
   (b) hanya tantangan kode (tanpa pemulihan), (c) tunda. Rekomendasiku (a), karena (b) membuat
   pengguna bisa terkunci permanen.
2. Kebijakan: apakah MFA wajib untuk peran tertentu atau opsional per pengguna? (rekomendasi:
   opsional, parameter default mati sampai pilot siap)
3. Batas percobaan verifikasi kode: parameter baru atau pakai `max_failed_logins`? (rekomendasi
   parameter sendiri, angka dariku)
4. Alur admin hapus/ganti faktor: izin apa, audit apa?
5. Masa kedaluwarsa pendaftaran `PENDING` (rekomendasi: parameter jam, angka dariku).

Setelah kujawab: D-xxx + task file bertahap (jangan satu commit raksasa), test: login dengan faktor
ACTIVE tanpa kode = 401/403 terdefinisi; kode salah berulang = terkunci; kode pemulihan sekali pakai;
faktor PENDING kedaluwarsa. **HUMAN-REVIEW-REQUIRED** (auth).
```

---

## O-024 — Komponen headless

```
Repo: /Users/sachiel/Projects/cbs. Bahasa dokumen: Indonesia; identifier kode: Inggris.
Tugas: putuskan O-024 (belum ada bits-ui/Melt UI; belum ada layar yang membutuhkan).

Baca: docs/OPEN_ITEMS.md O-024, packages/ui, docs/spec §14.1/§15.7, daftar backlog layar.

Jangan menulis kode dulu. Tanyakan:
1. Apakah ada layar berikutnya yang butuh dialog/combobox/tabel virtualized? Kalau tidak,
   rekomendasiku tunda + perbarui pemicunya.
2. Kalau ya: komponen mana dulu, dan apakah dependensi baru disetujui (butuh ADR singkat)?
3. Alternatif tanpa dependensi: implementasi dialog native `<dialog>` + pola combobox ARIA sendiri —
   apakah itu cukup? (rekomendasi: ya untuk dialog; combobox sendiri baru bila benar-benar perlu)

Setelah kujawab: kalau tunda, dokumentasi. Kalau ya, ADR + komponen + axe 2 tema + keyboard test.
```

---

## O-041 — Mekanisme invariant lintas-parameter

```
Repo: /Users/sachiel/Projects/cbs. Bahasa dokumen: Indonesia; identifier kode: Inggris.
Tugas: putuskan O-041 (baru ada satu aturan lintas-parameter: pasangan kebijakan sesi).

Baca: docs/OPEN_ITEMS.md O-041, D-027, `sessionPolicyCandidateProblem`, packs/base/seeds (params.yaml),
tools/paramgen.

Jangan menulis kode dulu. Tanyakan:
1. Apakah sudah ada aturan lintas-key kedua yang diketahui (bukan hipotetis)? Kalau tidak,
   rekomendasiku tunda — satu aturan tidak butuh mesin.
2. Kalau ya: bentuk deklarasinya di `params.yaml` (mis. `invariants:`) dan siapa yang memvalidasi
   (paramgen + submit + approve)? Rekomendasi: dipakai di ketiganya, satu implementasi.
3. Apakah aturan lama (sesi) ikut dipindahkan ke deklarasi itu, atau dibiarkan sebagai kode?

Setelah kujawab: kalau tunda, perbarui O-041 dengan pemicu. Kalau ya, D-xxx, paramgen + test,
pindahkan aturan sesi bila setuju, dan hapus kode khusus yang tergantikan (jangan dua implementasi).
```

---

## O-008 — Hardening server di luar repo

```
Repo: /Users/sachiel/Projects/cbs. Bahasa dokumen: Indonesia; identifier kode: Inggris.
Tugas: tindak lanjut O-008 (buffer deploy.log & hardening lain dari audit server 2026-10-13 §10).

Baca: docs/OPEN_ITEMS.md O-008, ops/scripts, docs/ACCEPTED-LIMITS, laporan audit di docs (cari
"audit server 2026-10-13").

Jangan mengubah server. Tanyakan:
1. Apakah kamu punya akses/izin untuk menjalankan perintah di VPS pada sesi ini? Kalau tidak,
   rekomendasiku: hasilkan checklist + perintah yang bisa kamu jalankan sendiri, bukan mengeksekusi.
2. Item audit mana yang masih relevan (buffer log, rotasi, firewall, SSH, dsb.)?
3. Apakah checklist ditulis di `ops/` (cermin konfigurasi) atau `docs/` (runbook)?

Setelah kujawab: tulis dokumen (bukan eksekusi), tautkan ke O-008, dan tandai item yang butuh
keputusan operator. Jangan menaruh secret di repo.
```

---

## SEMUA SEKALIGUS (satu sesi interaktif)

```
Repo: /Users/sachiel/Projects/cbs. Bahasa dokumen: Indonesia; identifier kode: Inggris.
Tugas: jalankan sesi keputusan interaktif untuk 17 open item di docs/agent/OPEN-ITEMS-PROMPTS.md.

Aturan sesi:
- Ikuti urutan risiko di berkas itu. Untuk setiap item: baca konteksnya, lalu tanyakan pertanyaan
  yang tertulis **satu per satu** (tunggu jawabanku; jangan menggabung).
- Setelah satu item dijawab: tulis keputusan di docs/DECISIONS.md + perbarui docs/OPEN_ITEMS.md,
  lalu implementasi HANYA item itu (kecuali jawabanku "tunda"), jalankan gate yang relevan, dan
  laporkan hasilnya sebelum pindah ke item berikutnya.
- Jangan mengarang angka/pasal. Angka parameter yang belum kutentukan harus kutanyakan.
- Jangan push ke main tanpa izin eksplisitku di sesi ini.
- Kalau satu item ternyata butuh perubahan besar (migrasi kontrak, auth, uang), tandai
  HUMAN-REVIEW-REQUIRED dan minta konfirmasi sebelum menulis kode.
Mulai dari O-067. Sebutkan item mana yang sudah selesai setiap kali kamu berpindah.
```
