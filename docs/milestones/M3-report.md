# M3 — Day-Close Framework: laporan milestone

Status: **SELESAI, menunggu keputusan manusia** (28 Okt 2026). Fase 3 spec §23: "`daycloser` penuh
(EOD/EOM/EOY), task deposit & ledger, simulasi, UI monitor"; kriteria selesai: **simulasi 12 bulan
sintetis lulus** dan **EOD 100k rekening simpanan + 50k pinjaman < 30 menit**.

Branch kerja: `feat/fase3-dayclose` (tidak pernah di-push ke `main`).

---

## 1. Yang selesai

| Task | Isi | Status |
|---|---|---|
| T-134 | Kerangka `daycloser`: state run/task/chunk, registry, orkestrator, `ctl` status | selesai |
| T-135 | Siklus business date (`OPEN → CLOSING → CLOSED → rollover`), gate deploy | selesai |
| T-136 | Gate pra/pasca-tutup (`DAY-3xx`), bukti di `task.metrics` | selesai |
| T-137 | Task ledger: snapshot saldo harian, tutup periode (EOM) | selesai |
| T-138 | Task deposit: akrual bunga harian, jatuh tempo/ARO, dormant | selesai |
| T-139 | API + UI monitor `/app/dayclose`, tombol resume/cancel, penjadwal `daycloser-auto` | selesai |
| T-140 | Simulasi 12 bulan, benchmark EOD, dry-run `SIMULATION`, laporan ini | selesai |

Pendukung: `docs/runbooks/dayclose.md` (operasi, kode `DAY-2xx`–`DAY-3xx`), `MODULE.md` untuk
`deposit`/`ledger`/`daycloser`, D-148…D-159.

## 2. Gate dan bukti

- `./task ci` **hijau** (28 Okt 2026): seluruh suite Nim (unit, property, integrasi), kontrak OpenAPI
  + klien TS sinkron, `paramgen --check`, `archcheck`, `lint-nomagic`, i18n id+en, vitest **142**,
  Playwright **59** (termasuk axe dua tema).
- Suite yang paling relevan: `itdaycloser_lifecycle` **10**, `itdaycloser_gates` **13**,
  `itdaycloser_ledger` **7**, `itdaycloser_auto` **7**, `itdaycloser_deposit` **33**,
  `itdaycloser_sim` **5**, `itapi_dayclose` **10**, `itapi_teller` **49**.
- Reviewer independen: T-138c/T-138d/T-138e diperiksa tiga putaran; seluruh `BLOCKER`/`MAJOR`
  diperbaiki sebelum `DONE` (bukti di `docs/tasks/T-138.md`).

## 3. Simulasi 12 bulan sintetis (kriteria §23)

`apps/api/tests/itdaycloser_sim.nim` — 1 Januari sampai 31 Desember 2026, **setiap hari kerja**
ditutup lewat `startRunAction` (jalur yang sama dengan `ctl`), dengan enam deposito berjangka
(`NONE` ×3, `PRINCIPAL` ×2, `PRINCIPAL_AND_INTEREST` ×1) dan dua tabungan. Hasil: 5 `[OK]`, ±12
detik. Invarian yang diperiksa di akhir tahun:

- setiap penutupan `COMPLETED` (gate `daycloser.*`, `ledger.*`, `teller.*` tidak ada yang gagal);
- saldo cache = subledger untuk setiap rekening, termasuk yang sudah `CLOSED`;
- tidak ada akrual ganda per rekening+tanggal, tidak ada akrual bukan nol tanpa jurnal, total akrual
  = debit `501` di GL;
- bunga yang dibayar pada ARO `NONE` sama dengan akrual terakhir rekening;
- `PRINCIPAL` memperpanjang tanggal jatuh tempo, `PRINCIPAL_AND_INTEREST` menambah pokok;
- tabungan yang tidak pernah dipakai menjadi `DORMANT`, tabungan tujuan tetap `ACTIVE`;
- total debit = total kredit, dan 12 periode bulanan `CLOSED`.

## 4. Benchmark EOD (§23)

`./task bench-eod --accounts N` — seed sintetis lalu **satu penutupan penuh** lewat service yang
sama dengan `ctl`. Lingkungan: MacBook lokal (Apple Silicon), PostgreSQL 18, `kran_test`, chunk 1000,
produk 2,5% ACT/365, saldo 10.000.000 per rekening.

**Cakupan yang diukur jujur**: seed tidak mengisi `maturity_date`/`aro_instruction`, jadi task
`deposit.maturity_aro` memindai halaman tetapi tidak memindahkan uang, dan tanggal 28 Okt bukan hari
kerja terakhir bulan sehingga `ledger.period_close` tidak berjalan. Angka di bawah mengukur jalur
**akrual + dormant + snapshot + gate**, bukan jalur tulis jatuh tempo atau tutup periode; keduanya
diukur di simulasi 12 bulan (`itdaycloser_sim`), bukan pada 100k rekening.

| Rekening | EOD | ms/rekening | Status |
|---|---|---|---|
| 100 | 0,13 s | 1,31 | `COMPLETED` |
| 1.000 | 0,62 s | 0,62 | `COMPLETED` |
| 10.000 | 6,57 s | 0,66 | `COMPLETED` |
| **100.000** | **133,45 s** | **1,33** | `COMPLETED` |

Target spec §23: 100k simpanan + 50k pinjaman **< 30 menit**. Sisi simpanan memakai **±7%** dari
anggaran waktu (133 detik dari 1.800 detik). Paralelisme chunk belum dibutuhkan pada angka ini
(`ACCEPTED-LIMITS`).

## 5. Deviasi dari spec

| Deviasi | Sebab | Dampak |
|---|---|---|
| **50k pinjaman tidak ada** | Modul `lending` baru Fase 4 | Kriteria "100k + 50k < 30 menit" **belum** diuji utuh; yang terbukti hanya sisi simpanan. Angka gabungan tidak diklaim |
| **`SIMULATION` = dry-run tingkat rencana**, bukan eksekusi di transaksi ter-rollback (§11.7) | Task menulis lewat pool sendiri; rollback tidak membatalkan efek di luar DB | Pratinjau menunjukkan task/chunk dan menolak keadaan yang toh ditolak, tetapi kegagalan tulis (`DAY-331`/`DAY-343`/`DAY-344`) baru terlihat saat run nyata (D-159) |
| **Chunk sekuensial**, belum ada `max_parallel` | Belum ada kebutuhan terukur | EOD 100k = 133 detik; paralelisme menyusul bila target gabungan menuntut |
| **Penutupan hanya scope `INSTITUTION`** | Scope cabang belum punya pemanggil | Run cabang ditolak/berakhir `FAILED` (`ACCEPTED-LIMITS`) |
| **Tidak ada timeout per task** | Belum diputuskan | Task menggantung menahan run sampai operator `daycloser-cancel` |
| **Benchmark di hardware lokal**, bukan VPS entry-level | Tidak ada akses benchmark VPS | Angka 133 detik adalah batas atas optimistis; perlu diulang di VPS sebelum pilot |
| **Benchmark tidak mengukur jalur tulis jatuh tempo/EOM** | Seed tanpa `maturity_date`, tanggal uji bukan akhir bulan | Angka 100k = akrual + dormant + snapshot + gate; jalur jatuh tempo & tutup periode dibuktikan di simulasi 12 bulan, belum pada skala 100k |
| **Tutup otomatis rekening dormant tidak ada** (§11.6 "tutup otomatis") | Keputusan produk/regulasi belum ada | Rekening dormant menumpuk; laporan tetap menampilkannya sebagai rekening hidup (O-114) |
| **Pencairan dini deposito diblokir** | Akrual kumulatif tidak punya jalur koreksi historis | Penarikan/PB yang menyentuh `TIME_DEPOSIT` ditolak 409 `time_deposit_locked` (D-156, O-108) |

## 6. Open items dan risiko

| Item | Risiko | Tindakan |
|---|---|---|
| O-108 pencairan dini + penalti | Anggota tidak bisa memecah deposito; belum ada keputusan produk | Keputusan pemilik/compliance: penalti, rule GL, koreksi akrual (baris pembalik) |
| O-109 siklus ARO kedua | Bunga siklus kedua/ketiga dinilai ulang pada pokok baru (model kumulatif D-154) — invarian akuntansi utuh, angka ekonomi salah | Wajib diputuskan sebelum deposito dibuka untuk anggota nyata |
| O-110 UNIQUE jurnal/subledger dilonggarkan | Laporan yang mengasumsikan "satu baris = satu jurnal" perlu disesuaikan | Konfirmasi audit/pemilik |
| O-111 `last_activity` tidak dipakai | Kolom kosong menyesatkan pembaca skema; komentar sudah diperbaiki (migrasi `deposit/0072`) | Hapus kolom (kontrak) atau tulis di semua jalur mutasi |
| O-112 race setoran vs penutupan | Hanya terbuka bila `txn_policy_during_close = ALLOW`; sisi dormant sudah ditutup predikat | Kunci baris atau tolak setoran ke rekening yang berubah status |
| O-113 audit transisi dormant | Tidak ada audit per rekening; hanya `updated_at` | Putuskan bentuk audit (per rekening vs ringkasan per chunk) |
| O-114 tutup otomatis dormant | Rekening dormant tidak pernah ditutup | Keputusan produk/regulasi, lalu task terpisah |
| Angka regulasi bertanda `NEEDS-COMPLIANCE-REVIEW` | Rate default, ambang dormant 12 bulan, akun `204`/`202`, SHU belum diverifikasi | Compliance officer meninjau sebelum pilot (spec §1.8) |

**HUMAN-REVIEW-REQUIRED** (AGENTS.md §8): rumus bunga/akrual, pergerakan uang jatuh tempo, dan guard
D-156 — semuanya sudah diuji, tetapi tetap area kritis yang butuh tinjauan manusia.

## 7. Saran langkah berikutnya

1. **Tinjauan milestone oleh pemilik** — hentikan di sini (AGENTS.md §7). Keputusan yang menunggu:
   O-108 (pencairan dini), O-109 (siklus ARO kedua), O-110 (UNIQUE subledger), O-113/O-114 (audit &
   tutup otomatis dormant), dan verifikasi angka regulasi.
2. Bila deposito akan dipakai anggota nyata: selesaikan O-109 + O-108 lebih dulu.
3. Benchmark ulang di VPS setelah deploy, lalu putuskan apakah `max_parallel` perlu.
4. Fase 4 (lending) dimulai hanya setelah keputusan pemilik; target §23 baru bisa diuji utuh saat
   modul pinjaman ikut dalam satu penutupan.

**STOP** — tidak ada fase berikutnya yang dimulai tanpa persetujuan manusia.
