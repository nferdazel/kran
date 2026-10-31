# Lembar keputusan — 17 open item

Buat kamu, bukan buat agen. Tiap nomor = satu keputusan yang membuka jalan implementasi. Jawab
singkat saja, mis. `1A 2A 3B 4A ...`; kalau ada angka yang perlu kamu tentukan, tulis di belakang
opsinya (contoh: `4A retensi 30 hari`). Agen akan mencatat tiap jawaban sebagai D-xxx di
`docs/DECISIONS.md` sebelum menulis kode.

Rekomendasi kutandai **(rek)** — dipilih kalau kamu tidak punya preferensi lain.

---

## 1. O-067 — Penerus `effectiveTo` harus satu scope

Sekarang nilai BRANCH ber-`effective_to` hanya bisa ditutup oleh nilai BRANCH lain, padahal resolusi
parameter jatuh ke GLOBAL. Akibatnya pengajuan bisa ditolak padahal tanggalnya tercakup.

- **A (rek)** — Longgarkan: penerus boleh di scope mana pun yang tercakup resolusi (BRANCH ditutup
  GLOBAL boleh; GLOBAL tidak ditutup BRANCH).
- **B** — Terima sebagai batas; catat di `ACCEPTED-LIMITS.md`.
- **C** — Hapus `effective_to` sama sekali (nilai selalu diganti nilai baru).

## 2. O-044 — Kandidat parameter dinilai tanpa melihat visibilitas scope

- **A (rek)** — Hanya baris yang **terlihat** aplikasi yang dinilai (scope NULL + scope yang dibaca
  `institutionScope()`); baris tak terlihat dilewati.
- **B** — Batasi pengajuan kebijakan sesi hanya ke scope yang dibaca aplikasi.
- **C** — Biarkan seperti sekarang (konservatif, tapi bisa menolak tanpa sebab).

## 3. O-087 — Nilai parameter `json`

- **A (rek)** — Batas kedalaman + larangan tipe yang tidak dipahami konsumen.
- **B** — Validator JSON Schema penuh (lebih berat, perlu pustaka/ADR).
- **C** — Tolak semua nilai `json` sampai ada kebutuhan nyata.

## 4. O-093 — PII di `idempotency_key.response_body`

- **A (rek)** — Retensi berparameter + pembersihan harian (replay tetap utuh). **Butuh angka retensi
  (hari).**
- **B** — Enkripsi kolom (butuh kunci + migrasi data).
- **C** — Field allowlist per endpoint (paling aman, replay rapuh).
- **D** — Terima risiko (sudah dicatat D-118).

## 5. O-022 — Visual regression

- **A (rek)** — Baseline dibuat di runner Linux, di-commit, gate memblokir; 3 layar × 2 tema, locale
  `id`.
- **B** — Sama, tapi hanya artifact informasional (tidak memblokir).
- **C** — Tunda.

## 6. O-026 — `schemathesis`

- **A (rek)** — Tunda; validator sendiri dipertahankan, alasan dicatat.
- **B** — Tambah job CI Python + server hidup (maks 15 menit).
- **C** — Jalankan manual di mesin developer saja.

## 7. O-028 — Kuota antrean realtime

- **A (rek)** — Ukur dulu di beban nyata, kuota ditentukan kemudian.
- **B** — Langsung pasang kuota parameter + putus klien lambat (`queue_overflow`, resync).
- **C** — Tunda tanpa pengukuran.

## 8. O-053 — Terjemahan role/izin

- **A (rek)** — Tunda sampai layar administrasi peran ada; catat pemicunya.
- **B** — Kerjakan sekarang (butuh daftar teks role/izin yang kamu setujui).
- **C** — Berhenti menyimpan `name_key`; simpan teks langsung.

## 9. O-064 — Menandai nilai parameter berakhir

- **A (rek)** — Tunda sampai ada kebutuhan nyata; catat pemicunya.
- **B** — Implementasi sekarang: field `endAt` + maker-checker + audit; pembacaan sesudahnya =
  `ParamNotFound`.

## 10. O-070 — `param.changed` per cabang

- **A (rek)** — Kirim perubahan yang **berlaku untuk cabang pelanggan** (termasuk GLOBAL/INSTITUTION);
  yang tidak terlihat disaring.
- **B** — Kirim hanya perubahan ber-scope cabang itu sendiri.
- **C** — Tunda.

## 11. O-075 — Akun kontra

- **A (rek)** — Tunda sampai pilot butuh CKPN/penyusutan; catat pemicunya.
- **B** — Implementasi penanda `contra` sekarang (+ laporan & property test neraca).

## 12. O-100 — Iuran & ekuitas simpanan pokok/wajib

- **A (rek)** — Tetap provisoris `301.1`/`301.2` dengan tanda `NEEDS-COMPLIANCE-REVIEW`; final
  ditentukan accounting owner sebelum data nyata.
- **B** — Tetapkan sekarang sebagai ekuitas (butuh rujukan yang sudah diverifikasi).
- **C** — Tetapkan sekarang sebagai liabilitas.

## 13. O-114 — Tutup otomatis rekening dormant

- **A (rek)** — Fase 1 hanya rekening **bersaldo nol** (tidak menyentuh dana anggota). **Butuh angka
  "setelah N bulan".**
- **B** — Semua saldo, dengan pemberitahuan + hak anggota (butuh aturan produk lengkap).
- **C** — Tunda.

## 14. O-071 — MFA diminta saat login

- **A (rek)** — Tantangan kode + kode pemulihan sekali pakai + batas percobaan + masa kedaluwarsa
  PENDING.
- **B** — Tantangan kode saja (risiko pengguna terkunci permanen).
- **C** — Tunda (tetap seperti sekarang: fitur mati).

## 15. O-024 — Komponen headless

- **A (rek)** — Tunda sampai ada layar yang membutuhkan; catat pemicunya.
- **B** — Pakai `<dialog>` native + pola ARIA sendiri (tanpa dependensi).
- **C** — Adopsi bits-ui/Melt UI (butuh ADR + dependensi baru).

## 16. O-041 — Mesin invariant lintas-parameter

- **A (rek)** — Tunda sampai ada aturan lintas-key kedua; catat pemicunya.
- **B** — Bangun sekarang: deklarasi `invariants:` di `params.yaml`, dipakai submit + approve +
  paramgen, aturan sesi dipindahkan ke sana.

## 17. O-008 — Hardening server — **DIBATALKAN (31 Okt 2026)**

Kamu putuskan ini di luar lingkup kran: itemnya server-wide (fond/sds/sshd/caddy/auditd) dan
ditangani di `~/Projects/vps`. Tidak ada pekerjaan di repo ini.

---

## Angka yang perlu kamu tentukan (kalau opsi terkait dipilih)

| Untuk | Angka | Usulanku (boleh diubah) |
|---|---|---|
| O-093 retensi idempotency | hari | 30 hari |
| O-114 tutup dormant saldo nol | bulan sejak aktivitas terakhir | 24 bulan |
| O-028 kuota realtime | jumlah pesan tertunda | ditentukan setelah pengukuran |
| O-071 batas percobaan kode MFA | kali | 5 kali |
| O-071 kedaluwarsa pendaftaran PENDING | jam | 24 jam |

---

## Yang tidak perlu kamu putuskan (sudah jelas arahnya)

- **O-100** arah teknis mengikuti jawaban 12; angka iuran tetap di luar sistem sampai Fase 5.
- **O-022** pembuatan baseline selalu di runner/container yang sama dengan gate — kalau memilih B,
  baseline tetap harus dari Linux.
- Semua item yang kamu pilih "tunda" akan tetap terbuka di `OPEN_ITEMS` dengan pemicu tertulis,
  bukan hilang diam-diam.
