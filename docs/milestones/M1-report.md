# Laporan Milestone M1 — Fase 1 (Core Ledger & Party)

Tanggal: **20 Oktober 2026**. Branch: `feat/fase1-party` di atas `3f55dad` (deploy Fase 0),
**belum di-merge ke `main`** — push ke `main` = deploy, merge hanya oleh manusia (AGENTS §3).

Fase 1 = deliverable spec §23: "Jurnal immutable, TB, produk parametrik" dengan bukti
"property test double-entry lulus". Implementasi T-070…T-077 selesai. **T-073 menunggu review
ulang setelah perbaikan r1, dan T-077 menunggu verdict review** (DoD §6), jadi milestone ini belum
ditutup. Tidak ada task `READY` tersisa selain T-079 (UI, sengaja menunggu ratifikasi D-075 dan
permintaan pemilik).

## 1. Yang selesai

| Task | Hasil | Commit | Review |
|---|---|---|---|
| T-070 | `party` inti: CIF dari parameter (pola + Luhn di kode), identitas dasar, dua gerbang institusi/cabang | `5d6e84b`, `3aaa687` | APPROVE |
| T-071 | KYC/risiko: dokumen identitas terenkripsi (ciphertext + blind index + `number_last2`), unmask beralasan + audit, rating risiko | `c4aa8d4`, `f264e96` | APPROVE, **HUMAN-REVIEW-REQUIRED** |
| T-072 | COA (pola dari parameter, sisi normal dari tipe akun via CHECK) + periode (inklusif, `EXCLUDE`) | `e5f7688`, `62bf45f` | APPROVE (r2) |
| T-073 | Jurnal immutable + pembalik: satu pembalik per jurnal, header+baris satu transaksi, periode tertutup ditolak, idempotency | `d7374db`, `bac5970` | r1 CHANGES-REQUIRED; review r2 menyusul |
| T-074 | Posting rule sebagai data + konsumen outbox (`platform.inbox`), lease claim, `journal.posted`, worker long-running | `b1de872`, `bac5970`, `8b48e51` | APPROVE (r2) |
| T-075 | Trial balance dari `journal_line`; `balance_snapshot` cache kumulatif yang dapat direkonstruksi | `bac5970`, `8b48e51` | APPROVE |
| T-076 | `product` factory: `product`/`product_version`/`product_param_binding`, versi inklusif tanpa tumpang tindih, binding = parameter, `ProductPublished` | `997fafd`, `4930514`, `534221b` | APPROVE (r3) |
| T-077 | Alur end-to-end Fase 1 + laporan ini | `9a04d50`, `abc3ec8`, `09d2c46` | APPROVE (r2) |
| — | Arah UI "buku besar, kulit hangat" + memo SME (bahan Fase 2) | `1111948` | D-075 |

## 2. Bukti gate

- `./task ci` pada **HEAD `abc3ec8`** (format, lint, archcheck, lint-nomagic, paramgen --check,
  i18n, OpenAPI + klien TS, unit + property + integrasi Postgres, e2e Playwright/axe):
  **hijau — 816 `[OK]`, e2e 24 passed, 627 detik** (log: `/tmp/ci-head2.log`; angka juga di
  `docs/PROGRESS.md`). Run sebelumnya gagal karena **tunnel SSH DB dev putus** di tengah jalan,
  bukan regresi kode; watchdog menyambung ulang dan run diulang pada commit yang sama.
- **Migrasi dari DB kosong** diverifikasi pada cluster PostgreSQL sementara (bukan DB dev yang
  sudah berisi): 32 migrasi diterapkan berurutan, `btree_gist`, EXCLUDE versi produk, dan kolom
  `sealed` ada. Ini menutup BLOCKER review T-076 (urutan migrasi `product/0002` vs
  `platform/0004`).
- **End-to-end Fase 1** (`itapi_fase1`): party (CIF dari parameter) → produk (versi + binding) →
  event `DepositPosted` dikonsumsi worker → jurnal double-entry seimbang → TB cocok nominal →
  `ProductPublished` + `journal.posted` terbit → pembalik menetralkan saldo per akun tanpa
  mengubah jurnal asal.
- Unit/property yang mengunci uang & double-entry: `Money`/`Rate` fixed-point (tanpa float),
  property test jurnal seimbang, property test TB, pembulatan param-driven.
- Test integrasi DB me-reset schema modul sebelum migrasi (disiplin harness), tetapi jalur DB
  kosong diuji terpisah seperti di atas.

## 3. Deviasi dari spec (keputusan tercatat)

| Hal | Spec | Yang dibangun | Alasan |
|---|---|---|---|
| Partisi jurnal | §9.3 menyebut partisi | **Tidak dipartisi** (D-072) | Pilot <5.000 anggota; partisi menambah kompleksitas tanpa bukti beban. Ditinjau sebelum volume tinggi. |
| Posting rule | aturan akuntansi | **Data** (`posting_rule` + lines, seed migrasi, JSON condition) (D-073) | Tidak ada angka/akun di kode; kondisi paling spesifik menang, ambiguitas gagal terlihat. |
| Saldo | laporan saldo | TB = **pergerakan periode**; `balance_snapshot` hanya cache kumulatif (D-074, O-083) | TB untuk memeriksa keseimbangan; neraca/saldo awal butuh task laporan. |
| Bentuk tabel `product` | hanya nama tabel (§9.1(5)) | Kolom diturunkan; rentang inklusif; versi immutable + binding sealed (D-076) | Spec tidak memberi DDL. |
| Layar UI | §15/§17 | Fase 1 tanpa UI baru; arah visual dicatat (D-075), migrasi token = T-079 | UI teller baru di Fase 2; token produksi tidak diubah tanpa ratifikasi. |
| CSP | §13 | `<meta>` hash mode (D-045) | Keterbatasan SvelteKit; bukan penurunan keamanan yang material. |

## 4. Open items yang butuh pemilik / compliance

**Keputusan pemilik**
- **O-066**: seed parameter `party.*`/`ledger.*`/`product.*` di produksi (nilai final).
- **O-072**: cakupan idempotency (header vs endpoint lain).
- **O-075**: akun kontra untuk produk tertentu.
- **O-080**: API pengelolaan posting rule (sekarang seed migrasi).
- **O-081**: monitoring worker + enable boot unit `kran-worker`.
- **O-082**: tampilan desimal uang di UI.
- **O-085**: maker-checker untuk perubahan produk (sekarang izin `manage` langsung).
- **D-075 / T-079**: ratifikasi arah UI sebelum token produksi dimigrasi.
- Ganti password admin awal; rollout Fase 1 (deploy + seed) belum dilakukan.

**Compliance / belum terverifikasi (NEEDS-COMPLIANCE-REVIEW)**
- Nilai & pasal regulasi §4 (O-001) tetap belum diverifikasi; seed parameter produk/posting
  ditandai.
- **O-071**: KEK belum ter-mount di produksi → endpoint field-crypto menjawab 501.
- **O-084**: atribut rate/day-count/fee lanjutan produk belum dimodelkan.
- **O-083**: saldo awal akun yang tidak bergerak belum tampil di TB.
- **O-086**: guard `xmin` jurnal bergantung pada asumsi tanpa savepoint + epoch xid.
- **O-087**: binding `pvtJson` hanya dibatasi ukuran; batas schema pecahan ditolak fail-closed.

**Teknis tertunda**: O-009 (`daycloser` belum ada), O-027 (sisa job `traceability`, bukan tabel
Fase 6), O-065, O-076…O-079 (catatan review sebelumnya), O-088 (jalur migrasi DB kosong tidak
tercakup `task ci` lokal; job CI `db-tests` sudah ada). O-068 **selesai** (T-060).

## 5. Risiko

1. **Regulasi belum diverifikasi** — nilai parameter dan tag `@REG-xxx` masih perlu review
   compliance sebelum dipakai koperasi nyata. Mitigasi: semua nilai dari parameter + tanda
   `NEEDS-COMPLIANCE-REVIEW`.
2. **KEK belum ada di produksi** — fitur identitas terenkripsi tidak dapat dipakai sampai
   O-071 selesai; jangan mengaktifkan alur KYC penuh sebelum itu.
3. **Worker belum di-enable saat boot** (O-081) — event akuntansi akan menumpuk di outbox
   sampai worker dijalankan; monitoring belum ada.
4. **Tanpa maker-checker produk** — perubahan biaya/limit berlaku langsung. Untuk pilot dengan
   satu operator dapat diterima; sebelum multi-operator, O-085 wajib.
5. **Migrasi DB kosong** — job CI `db-tests` sudah menerapkan migrasi ke `kran_test` kosong, dan
   jalur ini juga diuji manual pada cluster PG sementara. Yang belum tercakup: `./task ci` lokal
   (schema di-reset tanpa melepas ekstensi), jadi regresi urutan/checksum baru terlihat setelah
   push (**O-088**).

## 6. Rekomendasi langkah berikut

1. **Merge `feat/fase1-party` → `main` oleh pemilik** (deploy) setelah: (a) verdict **T-073 r2**
   keluar (perbaikan BLOCKER pembalik ganda belum direview ulang), (b) keputusan O-066/O-081, dan
   (c) penggantian password admin.
2. **Fase 2 (teller)**: mulai dari T-079 (token UI + IBM Plex) hanya setelah D-075 diratifikasi,
   lalu alur setor/tarik dengan produk `product.savings.*` yang sudah ada.
3. Sebelum go-live koperasi: selesaikan O-071 (KEK), O-081 (worker + alert), O-066 (nilai
   parameter), dan review compliance §4.
4. **STOP** — sesuai AGENTS §7, menunggu keputusan pemilik sebelum memulai Fase 2.

## 7. Tanda HUMAN-REVIEW-REQUIRED

- T-071: enkripsi dokumen identitas, blind index, alur unmask + audit.
- T-073: jurnal immutable, pembalik, guard periode/`xmin`.
- T-074: konsumen outbox (idempotency, lease, `journal.posted`).
- T-075: trial balance & cache saldo.
- T-076: validasi nilai parameter uang/rate untuk produk (parser kernel, batas schema).
- T-072: seed COA & posting rule bertanda `NEEDS-COMPLIANCE-REVIEW`.
