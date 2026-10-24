# Memo Keputusan — Tata Kelola Operator & Pemisahan Tugas (T-118)

**Status:** keputusan menunggu pemilik (lihat §6) · **Tanggal:** 24 Okt 2026 · **Lingkup:** pilot (1 koperasi,
1 cabang, data sintetis; O-004/D-046) · **Bukan kode, bukan migrasi.**

Sumber yang dibaca: `docs/OPEN_ITEMS.md` (O-097…O-104), `docs/ACCEPTED-LIMITS.md` §4c, spec §4/§9/§10/§13/§18.2,
`platform/migrations/0008,0020,0022…0029`, `modules/platform/{infrastructure/auth_service,domain/authz}.nim`,
`modules/teller/**`, `modules/ledger/**`. Setiap klaim di bawah dapat ditelusuri ke berkas yang disebut.

## 1. Fakta hari ini

**Siapa boleh apa (terverifikasi).**
- `platform_admin` adalah satu-satunya peran yang memegang **seluruh** izin: maker+checker parameter
  (`param.submit`+`param.approve`, `0008`), maker+checker produk (`product.catalog.manage` di `0017/0018`
  + `product.catalog.approve` di `0022`), kas/vault (`teller.session.*`, `teller.transaction.post`,
  `teller.vault.topup`/`read` di `0024`/`0025`/`0026`), buku besar (`ledger.*` di `0015`/`0016`),
  registrasi (`deposit.account.manage` `0023`, `party.*` `0013`/`0014`), dan administrasi pengguna
  (`platform.user.manage`, `0029`).
- Peran lain sempit: `param_maker`/`param_checker` (`0008`), `product_checker` (`product.catalog.read`
  + `approve`, `0027`), `teller` = BRANCH (`teller.session.open/close/read`, `teller.transaction.post`,
  `teller.vault.read`, `deposit.account.read`, `party.party.read` — `0027`; + `platform.param.read`
  `0028`). **`teller` tidak punya `teller.vault.topup`.**

**Kontrol SoD yang benar-benar ada.**
- Tabel `platform.role_conflict` memuat **satu** pasangan: `param_checker`/`param_maker` (`0020`).
- `grantRole` **melempar** bila penugasan melahirkan pasangan tersemai (`auth_repo.nim:298`);
  `authorize`/`authorizeScoped` menolak siapa pun yang memegang pasangan apa pun izinnya
  (`authz.nim:158,187`) — pertahanan berlapis.
- Penjaga per-baris (bukan per-peran): `param_value_no_self_approval_chk` (`platform/0004:64`) dan
  `product_version_self_approval_chk` (`product/0003:34`). Efeknya: `platform_admin` **tidak bisa**
  menyetujui pengajuan **dirinya sendiri** untuk parameter/produk, tetapi tetap bisa menyetujui
  pengajuan orang lain dan menjadi satu-satunya kasir + pemberi vault.

**Penjaga admin terakhir.** `locksOutLastAdmin` (`auth_service.nim:460`) menolak **mencabut** peran
`platform_admin` atau **menonaktifkan** akunnya bila hanya tersisa satu pemegang `platform_admin`.

**Kas teller/vault.** Vault per cabang `numeric(24,4)`, sesi kas per (cabang,teller), `cash_movement`
immutable; `expected_cash = opening_float + Σ CASH_IN − Σ CASH_OUT`; `variance = counted − expected`;
tutup menambah vault sebesar `counted_cash` (`teller/MODULE.md`, `itsession.nim`). Top-up = increment
atomik + audit + event, tanpa maker-checker/alasan wajib (`handlers_teller_vault.nim`, T-107).

**Buku besar.** COA hanya `101 KAS`, `102 BANK`, `201/202`, `301`, `301.1/301.2`, `401/402`, `501/502`
(`ledger/0002`, `ledger/0014`). Setor/ tarik tunai sudah berjurnal (`DepositPosted` D101/K201,
`DepositWithdrawn` D201/K101 — `ledger/0012`), tetapi **buka/tutup sesi, top-up vault, dan selisih kas
tidak berjurnal** (O-097) — jadi saldo `teller.vault` tidak bisa direkonsiliasi ke `journal_line`.

**Hari ini vs parameter.** Tidak ada satu pun parameter `teller.*` yang tersemai (`modules/teller`
tidak punya `seeds/params.yaml`); limit kas dan nominal belum ada (O-099). `daycloser` **belum ada**
(O-013) — task EOD belum bisa menampung sweep kas. Master cabang **ada sejak D-130** (`platform.branch`
kode 3 digit + nama, `ctl create-branch`), tetapi belum ada endpoint/UI-nya; `branch_id` di modul lain
tetap UUID tanpa FK
placeholder (O-101). Pemisahan tugas efektif = tidak ada di produksi (O-102).

## 2. Risiko per celah

| Celah | Skenario gagal nyata (koperasi) | Severity | Yang menanggung |
|---|---|---|---|
| **O-102** satu akun memegang maker+checker+kas+vault | Bendahara/Kasir mengajukan parameter (mis. limit) lalu menyetujui lewat akun lain yang juga miliknya; atau menyetujui pengajuan pengurus tanpa jejak pemisah peran. Per-baris guard menahan self-approve **objek yang sama**, bukan pengajuan orang lain | Tinggi | Pengurus, anggota (kehilangan kontrol), auditor |
| **O-097** kas teller/vault tanpa GL | Top-up vault menaikkan `teller.vault.balance` tanpa akun lawan; uang kas di laci tak pernah masuk neraca. Selisih kas (`variance`) dicatat di `teller.teller_session` tetapi tidak diakui di buku. Neraca dan kas fisik tidak bisa direkonsiliasi → **temuan audit** "buku tidak dapat diandalkan" | Tinggi | Akuntan, pengurus; potensi sanksi pengawas |
| **O-098** top-up vault tanpa penyetuju kedua & tanpa batas | Satu pemegang `teller.vault.topup` menyuntikkan nominal tak terbatas tanpa persetujuan; note opsional sehingga tidak ada bukti sumber dana. Skema penggelapan berdimensi kecil yang khas koperasi kecil (kas "disuntik" untuk menutup selisih) tidak tertangkap lapis sistem | Tinggi | Anggota, pengurus |
| **O-099** tanpa limit kas/nominal | Teller menyimpan/mengeluarkan nominal tanpa plafon; tidak ada kontrol kepatuhan di jalur kas maupun ambang lapor APU-PPT | Sedang–tinggi | Teller (temuan), institusi (kepatuhan) |

## 3. Rekomendasi SoD

Sasaran: **jangan** menempelkan pasangan konflik ke `platform_admin` (peran itu wildcard — memasangkannya
akan membuatnya sendiri tidak bisa dipakai). Jalannya adalah **memecah** `platform_admin` menjadi peran
operasional sempit, lalu menyemai pasangan antar peran sempit itu.

**Matriks pasangan untuk `platform.role_conflict`** (bentuk kanonik `a < b`, `RolePair`):

| Role A | Role B | Mengapa | Prioritas |
|---|---|---|---|
| `param_maker` | `param_checker` | maker-checker parameter | **wajib** (sudah tersemai `0020`) |
| `product_maker` | `product_checker` | maker-checker katalog produk; `product_checker` sudah ada, pembuatnya belum | **wajib** |
| `ledger_admin` | `cash_admin` | yang membukukan tidak boleh mengendalikan injeksi kas/vault | **wajib** |
| `ops_admin` | `ledger_admin` | admin akun/RBAC bukan pemegang buku | *nice to have* |
| `ledger_admin` | `teller` | pemegang buku tidak sekaligus kasir | *nice to have* (bisa digabung di pilot 1 cabang dengan kontrol kompensasi) |
| `cash_admin` | `teller` | yang mengisi vault bukan yang menghitung laci | *nice to have* |

Catatan: pasangan *nice to have* tetap disemai; efeknya hanya "satu orang tidak boleh memegang
keduanya", bukan larangan operasional. Bila koperasi hanya punya 2 staf, aktifkan **hanya** yang
bertanda *wajib* + prosedur break-glass (§3 bola terakhir).

**Pemecahan `platform_admin` (usulan minimum).**

| Peran baru | Izin inti (dari katalog yang sudah ada) | Fungsi |
|---|---|---|
| `ops_admin` | `platform.user.manage`, `platform.param.read`, `platform.audit.read`, `party.*`, `deposit.account.manage`, `product.catalog.read`, `ledger.coa.read`, `ledger.period.read`, `teller.vault.read` | administrasi akun/anggota/rekening |
| `ledger_admin` | `ledger.coa.manage`, `ledger.period.manage`, `ledger.journal.read`, `ledger.journal.reverse`, `product.catalog.manage` | pembukuan, periode, COA, pembalik |
| `cash_admin` | `teller.vault.topup`, `teller.vault.read` | penyediaan kas/vault cabang |
| `product_checker` *(ada)* | `product.catalog.read`+`approve` | checker katalog |
| `param_checker`/`param_maker` *(ada)* | pasangan parameter | maker-checker parameter |
| `teller` *(ada, BRANCH)* | sesi + transaksi tunai | operasi laci |

**Headcount minimum.** SoD sejati butuh **≥ 2 orang**. Susunan termurah untuk 1 cabang:
- **Orang 1** = `ops_admin` + `param_maker`/`product_maker` (pembuat).
- **Orang 2** = `param_checker`/`product_checker` + `ledger_admin` + `cash_admin`? → **tidak boleh**
  (`ledger_admin`↔`cash_admin` wajib). Perlu **Orang 3** bila pasangan wajib ditegakkan penuh.
- Jadi minimum realistis: **3 akun** — (a) ops/maker, (b) checker/approver + ledger_admin, (c) cash_admin
  + teller. Bila koperasi hanya sanggup 2 akun: aktifkan pasangan *wajib* saja kecuali `ledger_admin`↔
  `cash_admin`, dan tutup celahnya dengan **break-glass** di bawah.

**Break-glass bila hanya satu orang tersedia.** Bukan fitur yang ada hari ini; usulan agar pemilik
menetapkannya sebagai *prosedur* dulu (kode menyusul bila dipilih):
1. Operasi ganda (maker=checker) hanya boleh untuk akun `platform_admin` cadangan yang **tidak**
   dipakai harian.
2. Wajib mengisi `reason`/note dan memicu audit + event (pola `withIdempotency` yang sudah ada).
3. Notifikasi/ laporan wajib ke pengurus paling lambat H+1 (pengurus/auditor menelaah).
4. Bila kelak dikodekan: parameter `platform.sod.break_glass.enabled` (default `false`) + izin
   tersendiri + `NEEDS-COMPLIANCE-REVIEW`; jangan diaktifkan tanpa keputusan tertulis.

**Apa yang penjaga admin terakhir lindungi dan tidak.**
- **Melindungi:** tidak bisa mengunci diri dari manajemen RBAC — `revokeUserRole` dan
  `disableUserAccount` menolak bila `locksOutLastAdmin` benar.
- **Tidak melindungi:** (a) peran kritis lain yang hanya dipegang satu akun (`param_checker`,
  `ledger_admin`, `cash_admin`, `teller` — tidak dihitung sama sekali); (b) seseorang yang memegang
  maker+checker+kas sekaligus — penjaga menghitung **pemegang `platform_admin`**, bukan pelanggaran SoD;
  (c) perpanjangan hak sebelum pencabutan (buat admin kedua lalu nonaktifkan yang lama) — sah by design;
  (d) reset kata sandi, pencabutan sesi, atau perubahan lewat SQL/CLI di luar alur HTTP.
  **Konsekuensi pemecahan:** bila peran harian berhenti memakai `platform_admin`, penjaga ini menjadi
  tumpul → **harus diperluas** ke peran admin baru (K-7).

## 4. Tata kelola kas/vault

**Penyetuju kedua top-up vault.** Usul: `teller.vault.topup` dipecah maker-checker — pengaju memakai
izin `teller.vault.topup.submit`, penyetuju `teller.vault.topup.approve`. Bukti yang wajib disertakan:
sumber dana fisik (slip penarikan bank / bukti setor ke rekening institusi), cabang, nominal, dan
alasan. Nominal **harus sama** antara pengajuan dan eksekusi.

**Mekanik maker-checker yang cocok dengan pola repo.** Bentuk paling dekat dengan yang sudah ada
(`platform.param_value` PENDING→ACTIVE, `product.product_version` DRAFT→ACTIVE):
- Tabel `teller.vault_topup_request` (`status` PENDING/APPROVED/REJECTED, `requested_by`, `decided_by`,
  `amount`, `note`, `decided_at`) + CHECK `decided_by <> requested_by` (pola `checker <> maker`).
- `POST …/vault/topups` menjadi *submit* (menulis PENDING, audit + event `TellerVaultTopUpRequested`);
  *approve* menerapkan increment atomik + audit + event `TellerVaultTopedUp` dalam **satu** `withDbTx`,
  di dalam `withIdempotency` (D-098). Jangan buat middleware maker-checker generik (D-098 menolaknya).
- Alternatif lebih murah (jika pemilik ingin sesedikit mungkin kode): wajibkan **dua izin** pada satu
  request (dua akun berbeda mengirim konfirmasi) — namun bentuk ini lebih lemah dan tidak disarankan.

**Kunci parameter limit kas** (nama saja — **nilai = keputusan pemilik**, `NEEDS-COMPLIANCE-REVIEW`;
efektif-dated lewat maker-checker):
- `teller.cash.limit_opening_float` — plafon saldo awal sesi.
- `teller.cash.limit_max_balance` — plafon kas di laci.
- `teller.cash.limit_transaction_max`, `teller.cash.limit_transaction_daily` — per transaksi & harian.
- `teller.cash.variance_tolerance` — ambang selisih sebelum wajib eskalasi/ review.
- `teller.vault.limit_topup_per_request`, `teller.vault.limit_topup_daily`, `teller.vault.limit_balance_max`.

## 5. Perlakuan GL O-097

Akar masalah: `101 KAS` tunggal — tidak membedakan kas di laci vs vault vs perjalanan; dan top-up/ float/
variance tidak berjurnal. Catatan: `daycloser` **belum ada** (O-013), jadi sweep EOD belum bisa
dititipkan; jurnal harus inline di handler atau di worker sampai Fase 3. Semua klasifikasi akun di bawah
**NEEDS-COMPLIANCE-REVIEW** (REG-011/SAK EP `V!`, spec §4).

**Opsi A — akun clearing kas-ditangan + sweep saat tutup.**
`101.1 KAS DI VAULT`, `101.2 KAS DI TELLER`, `101.9 KAS SELISIH`; `101 KAS` tetap induk.
- Buka sesi (float vault→laci): **D 101.2 / K 101.1**.
- Tutup sesi (uang fisik→vault): **D 101.1 / K 101.2**.
- Selisih lebih: **D 101.1 (uang nyata) / K 101.9**; selisih kurang: **D 101.9 / K 101.1**
  (nominal = `|variance|`, arah sesuai tanda).
- Top-up: **D 101.1 / K `<sumber>`** (`102 BANK` bila dari rekening, atau `101.9`/akun perjalanan bila
  tunai — sumber = keputusan pemilik).
- *Pro:* `teller.vault.balance` == GL `101.1` dan `expected_cash` == GL `101.2` bisa direkonsiliasi
  otomatis; variance terlihat di buku. *Kontra:* 2 akun baru + 4–5 rule + jurnal per buka/tutup
  (volume tinggi); butuh gate EOD "semua sesi tutup" (task `daycloser` Fase 3).
- **Dampak ke `daycloser`:** perlu task baru "tutup paksa/variance sweep" + gate; sebelum `daycloser`
  ada, jurnal diposting inline saat buka/tutup.

**Opsi B — vault langsung sebagai akun GL; laci di luar buku.**
`102.x KAS DI VAULT` (atau `101`), laci tetap subledger `teller.*`.
- Hanya top-up + penyesuaian vault berjurnal (**D 102.x / K `<sumber>`** untuk injeksi; sebaliknya untuk
  penarikan). Buka/tutup sesi **tidak** berjurnal (masih di dalam vault).
- *Pro:* jauh lebih sedikit jurnal; cukup untuk pilot. *Kontra:* kas di laci tak pernah masuk neraca;
  variance tetap tak diakui; rekonsiliasi hanya di batas vault — O-097 tinggal separuh tertutup.
- **Dampak ke `daycloser`:** gate EOD hanya cek saldo vault vs GL; kas laci tidak terperiksa.

**Opsi C — hanya top-up yang berjurnal (tambalan minimal).**
`D <akun kas> / K <sumber>` saat top-up; float/ variance tetap tanpa jurnal.
- *Pro:* menutup celah injeksi tanpa akun lawan dengan kode minimum. *Kontra:* neraca tetap tidak
  mencerminkan kas laci; tidak menyelesaikan O-097 sepenuhnya.

**Rekomendasi: Opsi A**, bertahap — semai `101.1`/`101.2`/`101.9` + jurnal buka/tutup/ top-up lebih
dulu (ini yang bisa diuji golden D/K), lalu serahkan gate EOD + sweep variance ke Fase 3. Bila pemilik
mau paling sedikit kode untuk pilot: Opsi C dulu, dicatat sebagai utang ke Fase 3.

## 6. Keputusan yang diminta dari pemilik

- **K-1 — Pasangan SoD mana yang disemai.** Opsi: (a) hanya *wajib*; (b) *wajib* + *nice to have*.
  **Rekomendasi:** (b) bila ≥3 akun; (a) bila hanya 2. *Konsekuensi:* (a) lebih longgar tapi jalan
  dengan 2 orang; (b) pemisahan lebih kuat, butuh ≥3 akun.
- **K-2 — Pecah `platform_admin`.** Opsi: (a) pecah `ops_admin`/`ledger_admin`/`cash_admin` dan
  hentikan pemakaian harian `platform_admin`; (b) biarkan satu `platform_admin` + break-glass.
  **Rekomendasi:** (a). *Konsekuensi:* (a) butuh peran+ migrasi izin dan ≥2 akun; (b) risiko O-102
  tetap, hanya tertutup prosedur.
- **K-3 — Headcount & break-glass.** Opsi: (a) 3 akun, tanpa break-glass; (b) 2 akun + break-glass
  terdokumentasi. **Rekomendasi:** (a) bila memungkinkan; jika tidak, (b) dengan kewajiban laporan H+1.
  *Konsekuensi:* (b) menambah jalur override yang harus diaudit dan ditelaah pengurus.
- **K-4 — Maker-checker top-up vault.** Opsi: (a) `submit`+`approve` dengan bukti sumber dana wajib;
  (b) status quo. **Rekomendasi:** (a). *Konsekuensi:* (a) menutup O-098 tapi menambah tabel+ rute+ UI;
  (b) injeksi kas satu tangan tetap terbuka.
- **K-5 — Nilai parameter limit kas.** Opsi: pemilik mengisi `teller.cash.limit_*` sekarang, atau
  menunda dengan menandai `NEEDS-COMPLIANCE-REVIEW` eksplisit. **Rekomendasi:** tetapkan angka (walau
  longgar) sebelum data anggota nyata. *Konsekuensi:* tanpa angka, jalur kas berjalan tanpa kontrol
  nominal (O-099); `NEEDS-COMPLIANCE-REVIEW` menandai bahwa angkanya belum final.
- **K-6 — Perlakuan GL O-097.** Opsi A (clearing + sweep), B (vault sebagai akun GL), C (hanya top-up).
  **Rekomendasi:** A bertahap, atau C untuk pilot bila kode harus minimal. *Konsekuensi:* A/B/C berbeda
  pada apakah kas laci & variance masuk neraca dan seberapa besar task `daycloser` bertambah.
- **K-7 — Perluas penjaga admin terakhir.** Opsi: (a) perluas ke `ops_admin`/`ledger_admin`/`cash_admin`
  (dan checker); (b) tetap hanya `platform_admin`. **Rekomendasi:** (a) bila K-2(a) diambil.
  *Konsekuensi:* (b) setelah K-2(a), tidak ada lagi penjaga yang mencegah penguncian RBAC.
- **K-8 — Apakah `teller` boleh `teller.vault.topup`.** Opsi: (a) tidak (tetap di `cash_admin`);
  (b) ya, dengan maker-checker. **Rekomendasi:** (a). *Konsekuensi:* (b) menambah pasangan konflik
  `cash_admin`↔`teller` menjadi wajib.

## 7. Yang TIDAK boleh dikarang

- Memo ini **tidak** menyatakan satu pun pasal/ tarif/ angka regulasi. Spec §4 yang bertanda `V?`/`V!`
  (termasuk REG-011 standar akuntansi) **belum terverifikasi** (O-001) — semuanya tetap
  `NEEDS-COMPLIANCE-REVIEW`.
- Di mana praktik koperasi/BPR Indonesia disebut sebagai kebiasaan (mis. kontrol kompensasi saat staf
  minim, plafon kas longgar di pilot), labelnya **`praktik umum`** — bukan kutipan hukum.
- Semua kode akun baru (`101.1`, `101.2`, `101.9`, dan akun sumber top-up) adalah **usulan struktur
  pilot**, bukan kutipan SAK EP/PSAK.
- Semua nama parameter limit adalah **usulan nama**; **nilainya keputusan pemilik**. Tidak ada angka
  yang ditetapkan di memo ini.
