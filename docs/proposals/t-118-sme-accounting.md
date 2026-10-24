# Memo SME Akuntansi — Limit Kas, Perlakuan GL Kas, Saldo Awal Vault (T-118)

**Status:** rekomendasi menunggu keputusan pemilik · **Tanggal:** 24 Okt 2026 · **Peran:** SME
akuntansi/keuangan koperasi simpan pinjam kecil (pilot KRAN) · **Bukan kode, bukan migrasi.**

**Lingkup:** pilot 1 koperasi, 1 cabang (kode `001`), data sintetis (D-046/O-004). Memo ini menjawab
tiga keputusan yang belum diambil: **K-5** (limit kas), **K-6** (konfirmasi GL kas), **O-105**
(selisih saldo awal vault + saldo induk `101`).

**Sumber yang dibaca:** `AGENTS.md`; `docs/proposals/t-118-operator-governance.md` §4–§6; `docs/DECISIONS.md`
D-129…D-132; `docs/OPEN_ITEMS.md` O-097/O-099/O-102/O-104/O-105; `docs/ACCEPTED-LIMITS.md`;
`modules/teller/MODULE.md`; `modules/teller/seeds/params.yaml`; `modules/ledger/seeds/params.yaml`;
`modules/ledger/migrations/0002,0006,0014,0033,0034`; `apps/api/src/handlers_teller*.nim`;
`apps/api/src/deposit_posting.nim`; `apps/api/src/handlers_journals.nim`; `docs/runbooks/vault-produksi.md`.

## 0. Fakta, asumsi, batas aturan

### 0.1 Fakta (terverifikasi dari repo/keputusan; tidak diubah)

- Vault pilot `teller.vault.balance` = 12.850.000; saldo awalnya 10.000.000 dibentuk seed SQL
  **tanpa jurnal** (D-129, `runbooks/vault-produksi.md`).
- Jurnal tunai historis (sebelum T-118) memakai akun induk `101` = 2.700.000. Jurnal T-118
  berjalan: `101.1` = 150.000, `101.2` = 0, `101.9` = 0. Total GL kas = 2.850.000 → selisih tepat
  10.000.000 terhadap vault.
- `ledger/0033` membuat `101` **non-postable** (induk) dan memindahkan rule `101`→`101.2`;
  `ledger/0034` menyemai rule `TellerSessionOpened/Closed/TellerCashOverage/Shortage`.
- **`101` tidak bisa lagi menjadi baris jurnal.** Trigger `ledger.assert_line_account_postable`
  (`0006:45-68`) menolak setiap `journal_line` yang akunnya `postable = false`. Trigger ini aktif
  (diuji `itjournal.nim:160` "akun header (postable=false) ditolak").
- Jurnal **tidak** dibuat lewat HTTP (`handlers_journals.nim:3`): hanya baca + pembalik. Pembuatan
  jurnal berasal dari **posting rule** + event (`postRuleJournalSync`/`postJournalSync`).
- `journal_line`/`journal` immutable; koreksi = jurnal baru (AGENTS §1.3).
- Belum ada parameter limit kas (`modules/teller/seeds/params.yaml` hanya punya
  `teller.vault.cash_account`); belum ada `daycloser` (O-013).

### 0.2 Asumsi (dinyatakan; harap dikoreksi bila salah)

- Pilot beroperasi 1 cabang tanpa setoran/penarikan antar-cabang maupun ATM; kas berpindah hanya
  vault ↔ laci teller.
- Saldo `101` = 2.700.000 adalah kas teller historis yang secara ekonomi ada di kas fisik
  (vault/laci) pilot, bukan aset lain.
- Tidak ada sesi teller `OPEN` saat rekonsiliasi (semua kas kembali ke vault).

### 0.3 Batas aturan (jangan dikarang)

- Semua klasifikasi akun (`101.1`/`101.2`/`101.9`, akun sumber saldo awal) dan angka limit adalah
  **usulan struktur/kebijakan pilot**, **bukan** kutipan SAK EP/PSAK/regulasi → `NEEDS-COMPLIANCE-REVIEW`
  (spec §4 `V?`/`V!`, REG-011, O-001).
- Ambang pelaporan APU-PPT disebut sebagai **kewajiban yang ada**, tetapi **angkanya tidak
  dikarang** — ditandai `NEEDS-COMPLIANCE-REVIEW`.
- Praktik plafon kas longgar / kontrol kompensasi staf minim disebut **kebiasaan umum**, bukan aturan.

---

## 1. K-5 — Nilai/parameter limit kas

### 1.1 Rekomendasi

Tetapkan **empat** parameter (nama final; nilai = kebijakan pilot, bukan regulasi). Tipe
`money`, `scopes: [GLOBAL, INSTITUTION]`, `schema: { minimum: 0 }`, `sensitivity: NORMAL`,
`provenance.class: kebijakan`, `provenance.compliance: NEEDS-COMPLIANCE-REVIEW`.

| key (usulan) | Makna | Dicek di | Rekomendasi nilai (pilot) |
|---|---|---|---|
| `teller.cash.limit_opening_float` | plafon opening float per sesi | `handlers_teller_sessions.nim` (buka) | `2000000.0000` (Rp2.000.000) |
| `teller.cash.limit_deposit` | plafon **setor** tunai per transaksi | `handlers_teller.nim` (setor) | `10000000.0000` (Rp10.000.000) |
| `teller.cash.limit_withdrawal` | plafon **tarik** tunai per transaksi | `handlers_teller.nim` (tarik) | `5000000.0000` (Rp5.000.000) |
| `teller.vault.limit_topup_per_request` | plafon **top-up** per pengajuan | `handlers_teller_vault.nim` (submit) | `25000000.0000` (Rp25.000.000) |

**Opsional (usulan, boleh ditunda):** `teller.vault.limit_balance_max` (`50000000.0000`, plafon kas
vault), `teller.cash.limit_transaction_daily` (`50000000.0000`, setor/tarik akumulasi harian),
`teller.cash.variance_tolerance` (`10000.0000`, ambang selisih sebelum wajib eskalasi).

**Dasar angka (semuanya kebijakan pilot, bisa diubah lewat maker-checker):** vault pilot 12.850.000,
sehingga float laci dijaga kecil (Rp2 jt) terhadap vault; plafon top-up (Rp25 jt) ±2× vault agar
injeksi besar jarang dan terlihat; setor dibatasi lebih tinggi dari tarik karena tarik menguras laci
dan berpengaruh ke `expected_cash`. **Ini bukan angka kepatuhan/regulasi.**

Catatan penting: limit opening float **bukan** pengganti cek saldo vault. Jalur sekarang sudah
menolak float > saldo vault (`insufficient_vault`, 409, `handlers_teller_sessions.nim:145-153`).
Limit hanya menambah plafon kebijakan di atasnya.

### 1.2 Mekanisme penolakan (409 vs 400)

- **409 Conflict** untuk pelanggaran limit — konsisten dengan konvensi repo (keadaan bisnis sah
  tetapi ditolak: `insufficient_vault`, `session_already_open` = 409, bukan 400).
  `reason` eksplisit: `cash_limit_exceeded` (setor/tarik/opening float) dan
  `topup_exceeds_limit` (top-up). Sertakan `limit` & `value` di `params` supaya klien tidak menebak.
- **400 Bad Request** tetap hanya untuk bentuk input salah (≤0, bukan desimal, `branchId`/`note`
  tidak sah). Jangan memakai 400 untuk pelanggaran limit, dan jangan 422 (tidak dipakai repo ini).
- **Di mana dicek:** di **handler** (`apps/api/src/handlers_teller.nim`,
  `handlers_teller_sessions.nim`, `handlers_teller_vault.nim`), membaca nilai parameter aktif dengan
  pola `activeValueJson` yang sudah dipakai `handlers_teller_vault.nim:62` untuk
  `teller.vault.cash_account`. Cek **sebelum** memanggil mutasi domain/repo (supaya vault/jurnal
  tidak tersentuh bila ditolak). **Domain tetap murni** (tanpa baca parameter). Bila parameter tidak
  terbaca → fail-closed (500, pola `VaultConfigError`), bukan diam-diam tanpa limit.

### 1.3 Opsi yang ditolak + alasan

- **Limit sebagai konstanta di kode.** Ditolak: melanggar AGENTS §1.2 (tidak ada nilai bisnis di
  kode) dan spec §10.5 (limit = kebijakan institusi).
- **Limit di domain/validator domain.** Ditolak: domain harus murni; parameter adalah data runtime.
  Pengecekan di handler menjaga domain tetap deterministik & teruji.
- **400 untuk pelanggaran limit.** Ditolak: 400 menyiratkan request cacat; limit adalah aturan bisnis
  → 409 (konsisten `insufficient_vault`).
- **Limit check lewat middleware generik.** Ditolak: menyimpang dari pola handler eksplisit repo dan
  D-098 (menolak middleware maker-checker generik) — jangan buat abstraksi baru tanpa ADR.

### 1.4 Biaya implementasi (repo ini)

Tanpa migrasi (parameter = data). (1) tambah 4–7 entri di `modules/teller/seeds/params.yaml`;
(2) regenerasi `paramgen` (kunci `P_teller_cash_limit_*`); (3) baca + tolak 409 di tiga handler;
(4) uji: `itapi_teller`, `itapi_teller_sessions`, `itapi_teller_vault` (batas tepat di angka, tepat
di atas, parameter tidak ada → 500); (5) perbarui `MODULE.md`, `ACCEPTED-LIMITS.md`, `OPEN_ITEMS.md`
(O-099). Estimasi: **±0,5–1 hari**.

### 1.5 Risiko bila tetap terbuka

O-099: tak ada kontrol kepatuhan nominal di jalur kas; top-up satu pengajuan bisa berapa pun
(maker-checker ada, tapi tanpa plafon); potensi temuan audit dan risiko kepatuhan APU-PPT
(`NEEDS-COMPLIANCE-REVIEW`).

### 1.6 Yang harus ditandatangani pemilik

(a) Empat angka di tabel §1.1 dan apakah opsi §1.1-opsional diambil; (b) tanggal efektif; (c)
pernyataan sadar bahwa angka = kebijakan pilot, bukan regulasi, dan akan ditinjau compliance.

---

## 2. K-6 — Konfirmasi perlakuan GL kas

### 2.1 Keputusan/rekomendasi

**Pemetaan `101.1`/`101.2`/`101.9` + rule buka/tutup/selisih sudah MEMADAI untuk pilot** (D-132),
tanpa akun perantara sweep/settlement tambahan. Alasannya: pilot 1 cabang — kas hanya berpindah
vault ↔ laci; `101.9 SELISIH KAS` sudah berfungsi sebagai akun suspens selisih. Akun perantara
(mis. "kas dalam perjalanan" untuk setoran bank/antar-cabang) **baru perlu** saat ada perpindahan
kas ke bank atau antar-cabang (Fase 3+) — dan itu **harus** akun baru lewat migrasi rule + uji
golden, bukan akun yang dikarang di handler.

**Konfirmasi dua hal SME:**

1. **Deviasi sadar yang sudah benar.** Kaki selisih memakai akun laci (`101.2`), bukan vault —
   **setuju**: setelah tutup (`D 101.1 / K 101.2` sebesar counted), saldo `101.2` = −variance;
   jurnal selisih menolkan `101.2`, dan `101.2`/`101.9` kembali nol setelah semua sesi tutup.
   Ini konsisten dengan invarian MODULE.md.
2. **Klasifikasi `101.9` perlu ditinjau (bukan blocker pilot).** `101.9` adalah ASSET/DEBIT, jadi
   selisih **lebih** (overage) meng-kredit akun aset → berpotensi bersaldo **kredit (negatif)**.
   Secara akuntansi, kas lebih umumnya pendapatan lain/lain-lain, bukan kontra-aset. Untuk pilot
   ini wajar dipakai sebagai akun suspens, **tetapi wajib di-clear dan ditelaah berkala**, dan
   klasifikasi finalnya `NEEDS-COMPLIANCE-REVIEW`. Catat sebagai item Fase 3 (rekonsiliasi/sweep).

### 2.2 Batas yang tetap ada sampai Fase 3 (`daycloser`)

- Tanpa **gate EOD** "semua sesi tutup & kas seimbang" (O-013) — sesi bisa tertinggal `OPEN`.
- Tanpa **sweep/tutup paksa** sesi lama dan tanpa **clear/settlement otomatis** `101.9`.
- Selisih **tidak** memicu eskalasi/review otomatis (hanya tercatat + audit + event).
- Tanpa **laporan rekonsiliasi** `teller.vault` ↔ `journal_line` per cabang (manual).
- Sumber dana top-up **tidak** diverifikasi ke rekening bank (modul tetap: bukti = alasan + akun COA).
- **Rekonsiliasi tidak akan cocok** sampai O-105 dikerjakan: target yang tertulis saat ini
  (`ACCEPTED-LIMITS.md:52`, "bandingkan `teller.vault` dengan `journal_line` akun `101.1`") **tidak
  dapat dipenuhi** karena saldo awal 10.000.000 belum dijurnal dan 2.700.000 tertinggal di induk
  `101`. Ini diperbaiki lewat O-105 (§3), bukan dengan menambah akun.

### 2.3 Yang perlu diuji golden (D/K)

- Buka `D 101.2 / K 101.1` sebesar float; tutup `D 101.1 / K 101.2` sebesar counted.
- Selisih lebih `D 101.2 / K 101.9`; kurang `D 101.9 / K 101.2`, nominal `|variance|`.
- **Nominal nol dilewati** (domain menolak jurnal nol) — uji float 0 / counted 0 / variance 0.
- **Siklus penuh**: setelah buka→transaksi→tutup, `101.2` = 0 dan `101.9` = variance; setelah
  sweep manual `101.9` = 0.
- **Idempotensi**: replay buka/tutup tidak menjurnal dua kali.
- **Presisi**: `numeric(24,4)`/`Money` (desimal string), tidak ada float.
- **Rekonsiliasi (setelah O-105)**: `teller.vault.balance` = GL `101.1` + GL legasi `101` per cabang.

### 2.4 Biaya / risiko

Implementasi K-6 **nol kode** (sudah D-132); yang bertambah hanya uji golden (§2.3) bila belum ada,
dan item Fase 3 (gate EOD + clear `101.9`). Risiko bila salah pilih sekarang: mengganti pemetaan
setelah ada jurnal = migrasi rule baru + uji golden (bukan edit handler) — mahal, jadi tanda tangani
pemetaan pilot sekarang.

### 2.5 Yang harus ditandatangani pemilik

(a) Pemetaan `101.1`/`101.2`/`101.9` final untuk pilot (`NEEDS-COMPLIANCE-REVIEW`); (b) menerima
batas §2.2 sampai Fase 3; (c) menyetujui bahwa `101.9` akan di-clear berkala dan diklasifikasi ulang
bila compliance meminta.

---

## 3. O-105 — Menutup selisih saldo awal 10.000.000 dan saldo induk 101 (2.700.000)

### 3.1 Temuan penting (teknis, harus dibaca sebelum memilih)

Ada dua masalah **terpisah**:

- **(A) Vault 10.000.000 tidak pernah dijurnal.** Ini kekurangan nilai di sub-akun kas; bisa
  diperbaiki dengan **jurnal baru** (§3.2).
- **(B) Saldo induk `101` = 2.700.000 harus "pindah" ke `101.1`/`101.2`.** Di sini ada temuan
  keras: **tidak mungkin** membuat jurnal `D 101.1 / K 101` untuk memindahkannya, karena trigger
  `ledger.assert_line_account_postable` (`0006:61-66`) **menolak setiap baris jurnal ke `101`**
  (non-postable). Menyunting jurnal lama juga dilarang (immutable). Artinya masalah (B) **bukan**
  soal nilai hilang — total kas GL (101 + 101.1 + 101.2 + 101.9) sudah = kas fisik − 10.000.000 —
  melainkan soal **atribusi sub-akun**: 2.700.000 tertinggal di kode induk yang tak bisa diposting.

### 3.2 Rekomendasi (A): jurnal saldo awal vault

Satu **jurnal penyesuaian satu kali** (jurnal baru, jurnal lama tidak disentuh):

```
businessDate : <tanggal awal periode buku yang OPEN — pemilik/akuntansi tetapkan; lihat §3.4>
sourceEvent  : LedgerCashOpening            (rule baru; usulan nama)
sourceRef    : b0000000-0000-4000-8000-000000000001   (cabang pilot, D-129)
D 101.1 KAS DI VAULT       10000000.0000
K <akun sumber>            10000000.0000    ← keputusan pemilik (§3.4), bukan pilihan SME
```

Referensi/bukti: `runbooks/vault-produksi.md` (eksekusi 23 Okt 2026) + D-129 + baris seed
`teller.vault`. `idempotencyKey` deterministik, mis. `opening-vault-001-2026-10-01`, agar sekali saja.

**Jalur implementasi (jangan lewat SQL mentah).** Karena jurnal hanya lahir dari posting rule
(`handlers_journals.nim:3`), usulkan: (1) migrasi menyemai rule `LedgerCashOpening` +
`posting_rule_line` `D 101.1 / K <akun sumber>`; (2) satu perintah `ctl` sekali-jalan
(`--role=ctl post-opening-balance`) yang memanggil `postRuleJournalSync` (audit + idempotent),
dijalankan owner seperti runbook. Ini **lebih mahal** daripada `INSERT` SQL langsung, tetapi
**teraudit** dan memakai jalur resmi; `INSERT` SQL langsung ke `ledger.journal` memenuhi trigger
tetapi **tidak** meninggalkan jejak audit — pilih hanya bila pemilik menerima celah audit itu
(tandai `HUMAN-REVIEW-REQUIRED`, AGENTS §8). Estimasi: **±1 hari** (rule + ctl + uji).

### 3.3 Rekomendasi (B): menyikapi saldo induk `101`

**Pilot: opsi B1 — biarkan `101` sebagai header legasi beku; TIDAK ada jurnal.** Ubah definisi
rekonsiliasi menjadi **agregat**, bukan `101.1` saja:

```
teller.vault.balance  ==  GL(101.1) + GL(101_legasi)   per cabang, saat tidak ada sesi OPEN
```

Perbarui `ACCEPTED-LIMITS.md:52` dan O-105 dengan definisi ini; `101` tidak dipakai lagi untuk
posting apa pun (sudah non-postable). Ini satu-satunya opsi yang menghormati imutabilitas jurnal
(AGENTS §1.3) **tanpa** menyentuh data historis.

**Opsi yang ditolak:**

- **B2 — jurnal `D 101.1 / K 101`.** *Ditolak secara teknis*: diblokir trigger `postable` (`0006`).
  Menulisnya akan gagal; bukan sekadar tidak rapi.
- **B3 — migrasi data menulis ulang `journal_line` `101` → `101.2`.** *Ditolak*: melanggar
  imutabilitas jurnal (AGENTS §1.3: koreksi = jurnal pembalik). Hanya boleh bila pemilik **eksplisit**
  memutuskan pengecualian + prosedur DB khusus; tidak direkomendasikan.
- **B4 — hapus/nolkan baris `101`.** *Ditolak*: merusak jejak audit & neraca historis.

### 3.4 Opsi akun sumber saldo awal vault — **keputusan pemilik, SME tidak boleh memilih**

Klasifikasi 10.000.000 mengubah neraca dan hak pemilik dana — ini ranah keputusan pemilik/legal,
`NEEDS-COMPLIANCE-REVIEW` (spec §4). Pilihan (D/K di bars 3.2):

| Sumber | Akun | Kapan tepat | Implikasi |
|---|---|---|---|
| (a) Modal disetor pendiri/pengurus | **butuh akun ekuitas baru**, mis. `301.9 MODAL DISETOR PENDIRI` (belum ada di COA) | bila 10 jt = setoran modal pendiri/pengurus | menambah ekuitas; hak atas SHU |
| (b) Titipan/kewajiban pengurus | **butuh akun liabilitas baru**, mis. `211 TITIPAN PENGURUS` (belum ada) | bila 10 jt = dana titipan yang akan dikembalikan | utang; bukan hak anggota |
| (c) Simpanan anggota | `301` / `301.1` / `301.2` | **hanya** bila 10 jt memang simpanan pokok/wajib anggota | mengubah klaim anggota; perlu bukti setoran |

SME **tidak boleh** memilih salah satunya: (i) COA saat ini hanya punya `301 MODAL ANGGOTA` +
`301.1`/`301.2` — tak ada akun modal-pendiri maupun titipan, jadi (a)/(b) **membutuhkan akun baru**
(keputusan akuntansi + kebijakan); (ii) klasifikasi ekuitas vs liabilitas menentukan hak dan
pertanggungjawaban uang nyata; (iii) implikasi pajak/SHU dan legalitas pendirian koperasi
(`NEEDS-COMPLIANCE-REVIEW`). Untuk pilot data sintetis, boleh dipilih sementara + ditandai
`NEEDS-COMPLIANCE-REVIEW`, tetapi **harus** dikonfirmasi pemilik sebelum data anggota nyata.

### 3.5 Biaya / risiko

Biaya: (A) rule + `ctl` + uji ≈1 hari; (B1) hanya perubahan dokumentasi + uji rekonsiliasi agregat ≈0.
Risiko bila tetap terbuka: neraca tidak dapat direkonsiliasi ke `teller.vault` (temuan audit
"buku tak dapat diandalkan", O-105/O-097); netral — tidak ada nilai terbuka bila B1 dipilih, hanya
atribusi sub-akun.

### 3.6 Yang harus ditandatangani pemilik

(a) Akun sumber 10.000.000 (§3.4) **dan** persetujuan membuat akun COA baru bila (a)/(b); (b)
memilih B1 (agregat, direkomendasikan) atau mengecualikan imutabilitas jurnal untuk B3; (c)
`businessDate` & bukti jurnal; (d) pernyataan `NEEDS-COMPLIANCE-REVIEW` untuk klasifikasi.

---

## 4. Ringkasan keputusan yang diminta

| ID | Rekomendasi | Yang ditandatangani |
|---|---|---|
| K-5 | 4 parameter money: float 2 jt, setor 10 jt, tarik 5 jt, top-up/pengajuan 25 jt; tolak **409** `cash_limit_exceeded`/`topup_exceeds_limit` di **handler** | angka, opsi ekstra, tanggal efektif |
| K-6 | Pemetaan `101.1/101.2/101.9` + rule buka/tutup/selisih **memadai**; deviasi kaki selisih di `101.2` benar; batas EOD tunai = Fase 3 | pemetaan pilot + menerima batas §2.2 |
| O-105 | (A) jurnal `D 101.1 / K <sumber>` 10 jt via rule+ctl; (B1) biarkan `101` sebagai header legasi, rekonsiliasi = `101.1 + 101`; **`K 101` mustahil** (trigger) | akun sumber + pilihan B1/B3 |

## 5. Yang tidak boleh dikarang

- Tidak ada pasal/tarif/angka regulasi di memo ini. Semua rujukan klasifikasi/SAK/APU-PPT =
  `NEEDS-COMPLIANCE-REVIEW`. Ambang pelaporan APU-PPT **tidak** ditetapkan di sini.
- Semua kode akun (`101.1`/`101.2`/`101.9`, usulan `301.9`/`211`) = usulan struktur pilot, bukan
  kutipan standar.
- Semua angka limit (§1.1) = **kebijakan pilot**, bukan angka regulasi/kepatuhan.
- Praktik "float laci kecil", "plafon longgar di pilot", "clear akun suspens berkala" = **kebiasaan
  umum**, bukan kewajiban hukum.
