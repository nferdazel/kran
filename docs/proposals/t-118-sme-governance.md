# Memo SME Tata Kelola/Risiko Operasional — K-3, K-4, K-8 (T-118)

**Penulis peran:** SME tata kelola & risiko operasional (pemisahan tugas, kontrol internal) — koperasi
simpan pinjam kecil, pilot KRAN. **Status:** rekomendasi; keputusan tetap milik pemilik.
**Tanggal:** 24 Okt 2026 · **Lingkup:** pilot (1 koperasi, 1 cabang, data sintetis; O-004/D-046).
**Bukan kode, bukan migrasi.**

Lanjutan `docs/proposals/t-118-operator-governance.md` §3/§4/§6. Sumber yang dibaca:
`docs/DECISIONS.md` D-131, D-132; `docs/OPEN_ITEMS.md` O-097, O-102, O-103, O-105; `docs/ACCEPTED-LIMITS.md`
§4c; `modules/platform/migrations/0032_platform_rbac_admin_roles.sql`,
`modules/teller/migrations/0035_teller_vault_topup_approval.sql`,
`apps/api/src/handlers_teller_vault.nim`, `modules/platform/infrastructure/auth_service.nim`
(`locksOutLastAdmin`, `grantUserRole`), `modules/teller/domain/session.nim`,
`docs/runbooks/pilot-provisioning.md`, `docs/runbooks/vault-produksi.md`.

## 0. Cara membaca memo ini

- **Fakta** = dapat ditelusuri ke berkas yang disebut (nomor baris bila membantu).
- **Asumsi** = belum diverifikasi, dinyatakan sebagai asumsi.
- **Rekomendasi** = usulan keputusan, memakai mekanisme yang **sudah ada** (tanpa fitur besar bila
  prosedur cukup).
- Semua angka retensi/limit yang menyentuh kewajiban hukum ditandai **`NEEDS-COMPLIANCE-REVIEW`**.
  Memo ini **tidak** mengutip satu pun pasal/angka regulasi sebagai fakta.

## 1. Fakta (terverifikasi)

**Peran & izin (0032, 0035; memo T-118 §1/§3).**
- Peran tersedia: `platform_admin` (break-glass, **tidak** dipasangkan konflik), `ops_admin`,
  `ledger_admin`, `cash_admin`, `product_maker`, `product_checker`, `teller`, `param_maker`,
  `param_checker`.
- Pasangan konflik tersemai di `platform.role_conflict` (0032:82): **wajib** `product_maker`↔`product_checker`
  dan `cash_admin`↔`ledger_admin`; **nice-to-have** `ledger_admin`↔`ops_admin`, `ledger_admin`↔`teller`,
  `cash_admin`↔`teller`. Kelimanya **ditegakkan** (`grantRole` melempar, `authz` menolak — `auth_repo.nim:337`,
  `authz.nim:158,187`).
- Top-up vault (0035): izin `teller.vault.submit` dipegang **`cash_admin`, `ops_admin`, `platform_admin`**;
  `teller.vault.approve` dipegang **`cash_admin`, `platform_admin`**. `teller` **tidak** memegang keduanya
  (0035:63-78). Self-approval ditolak CHECK DB `vault_topup_self_approval_chk` (0035:43) **dan** handler
  (`handlers_teller_vault.nim:305-309,471-476`) — berlaku untuk **semua** peran, termasuk `platform_admin`.
- Penjaga penguncian-keluar (`auth_service.nim:462-483`) menghitung pemegang izin **`platform.user.manage`**
  (`platform_admin` **dan** `ops_admin`), bukan kode peran: `revoke-role`/`disable-user` atas pemegang terakhir
  ditolak (`reason = last_admin`).

**Bukti yang sudah ada di DB/API (0035; handler).**
- `teller.vault_topup_request`: `request_id`, `branch_id`, `amount numeric(24,4)`, `source_account` (FK
  `ledger.coa_account`), `note text` (**wajib, 1–200 karakter**, 0035:31), `status`, `requested_by`,
  `decided_by`, `decided_at`, `decision_note`, `journal_id`, `created_at`.
- `note` max 200 karakter (`session.nim:16` `maxSessionNoteLength = 200`). Reject wajib `reason`
  (handler:442). Approve tidak berbadan; nominal/akun sumber disetujui **apa adanya**.
- Persetujuan menulis saldo vault + jurnal `D <teller.vault.cash_account> / K <source_account>` + audit
  `teller.vault.topup.approve` + event, satu transaksi (handler:311-385).
- **Tidak ada** kolom/berkas lampiran, unggah dokumen, atau penyimpanan scan (grep `modules/teller`
  untuk `evidence|attachment|upload|scan|document`: nol hasil). Bukti = `note` + `platform.audit_log`.

**Keadaan nyata hari ini.**
- Produksi pilot: 3 akun — `admin` (`platform_admin`), `checker.pilot` (`product_checker` +
  `cash_admin`), `teller.pilot` (`teller`, 1 cabang) (`runbooks/pilot-provisioning.md:23-40`).
- `docs/ACCEPTED-LIMITS.md:16`: **pilot satu operator sudah terblokir** alur maker-checker
  (`checker <> maker` → 409 `self_approval`) untuk produk/parameter; dan alur top-up butuh akun kedua.
- **Tidak ada** batas nominal kas (O-099), UI top-up vault (O-103), prosedur tertulis override
  break-glass, dan kebijakan retensi bukti.

## 2. Asumsi (belum diverifikasi)

- A1: Pilot beroperasi pada hari/bulan kerja normal; pekerjaan harian = administrasi user/anggota/rekening,
  kas laci (`teller`), penyediaan vault (`cash_admin`), dan pembukuan (`ledger_admin`).
- A2: Perubahan produk/parameter jarang (bulanan), sedangkan top-up vault berulang (mingguan) — asumsi
  volume, bukan angka yang diputuskan.
- A3: Setiap manusia hanya memakai satu akun pribadi; tidak ada berbagi kata sandi (ini **aturan** yang
  diusulkan di K-3, bukan keadaan sekarang).

---

## 3. K-3 — Headcount minimum & aturan break-glass (yang bisa dieksekusi)

### 3.1 Jumlah minimum

**Rekomendasi (diputuskan sebagai aturan): minimum 3 akun/orang operator harian; target 4; plus 1 akun
break-glass terpisah (tersegel).**

Alasan berbasis grafik konflik yang **sudah tersemai**: `cash_admin`, `ledger_admin`, dan `teller`
saling berpasangan (segitiga `cash_admin`↔`ledger_admin`, `ledger_admin`↔`teller`, `cash_admin`↔`teller`),
jadi ketiganya **wajib tiga akun berbeda**. Satu akun lagi dibutuhkan bila pasangan `ledger_admin` juga
harus terpisah dari `ops_admin` dan dari `cash_admin` (nice-to-have `ledger_admin`↔`ops_admin` + wajib
`ledger_admin`↔`cash_admin`) — artinya pembukuan sebaiknya dipegang orang keempat.

Tata letak yang dieksekusi (target 4 akun harian + 1 break-glass):

| Akun | Role | Fungsi harian | Tidak boleh juga memegang |
|---|---|---|---|
| O1 | `ops_admin` (+ opsional `product_maker`/`param_maker`) | administrasi user/anggota/rekening; **pengaju** top-up | `ledger_admin` |
| O2 | `cash_admin` | penyediaan kas/vault; **penyetuju** top-up | `ledger_admin`, `teller` |
| O3 | `teller` | kasir laci (sesi, transaksi tunai), `setoran/penarikan` | `cash_admin`, `ledger_admin` |
| O4 | `ledger_admin` (+ opsional `product_checker`/`param_checker`) | pembukuan, periode, COA, pembalik | `cash_admin`, `ops_admin`, `teller` |
| BG | `platform_admin` | **break-glass saja**, tidak dipakai harian | — (wildcard, sengaja tidak dipasangkan) |

**Fallback 2–3 orang (harus dinyatakan sadar, bukan default).** Bila koperasi hanya sanggup **3 orang**:
gabung `cash_admin` ke O1 (`ops_admin` + `cash_admin`, tidak berkonflik). **Konsekuensi yang harus diterima**:
hanya ada **satu** pemegang `cash_admin`, sehingga setiap top-up butuh penyetuju lain — dan karena
`teller`/`ledger_admin` tidak boleh jadi `cash_admin`, penyetuju satu-satunya adalah akun **BG**
(`platform_admin`). Artinya pada susunan 3 orang, **persetujuan top-up rutin memakai break-glass** → SoD
tidak lagi bermakna untuk jalur kas. Karena itu 3 orang hanya boleh bila pemilik menerima frekuensi
break-glass harian + kewajiban laporan (3.4).

**Bila hanya 2 orang:** secara struktural alur maker-checker tidak bisa diselesaikan tanpa memakai BG
untuk **setiap** operasi ganda (fakta: `docs/ACCEPTED-LIMITS.md:16`). Ini diterima hanya sebagai keadaan
sementara dengan laporan H+1 (3.4), dan dicatat di `OPEN_ITEMS.md`.

### 3.2 Siapa boleh memakai `platform_admin` (BG)

- **Dilarang** dipakai sebagai login harian. Kredensialnya disegel (amplop/berkas mode ketat) dan dipegang
  **pengurus/owner**, bukan operator harian.
- Boleh dipakai **hanya** untuk dua hal:
  1. **Menjadi akun kedua** pada operasi ganda (maker=checker) saat manusia pembanding tidak ada
     (cuti/berhenti/force majeure). Operasi ganda = operator memakai akun hariannya sebagai *maker*, lalu
     BG sebagai *checker* (dua **user id** berbeda → lolos `vault_topup_self_approval_chk`).
  2. Perbaikan konfigurasi sekali jalan yang tidak punya jalur peran lain.
- **Tidak sah** memakai BG untuk melewati kontrol struktural: self-approval objek yang sama tetap ditolak
  CHECK DB/handler (fakta §1), `locksOutLastAdmin` tetap menjaga akses RBAC.

### 3.3 Syarat, bukti, dan pelaporan tiap kali break-glass dipakai

Setiap pemakaian BG **wajib** menghasilkan 4 bukti:
1. **Audit sistem** (sudah otomatis): `platform.audit_log` mencatat aksi + aktor + `reason`/`note` (untuk
   top-up: `teller.vault.topup.submit`/`.approve`, handler:127,358). Karena `note` ≤200 karakter, ringkas.
2. **Buku Break-glass** (prosedur, berkas digital atau buku fisik) berisi minimal: waktu (UTC+7), akun
   harian (maker), akun BG (checker), operasi, objek/`request_id`/`journal_id`, alasan singkat, siapa
   menandatangani, waktu laporan H+1, dan inisial pengurus penelaah.
3. **Laporan tertulis ke pengurus paling lambat H+1** (pengurus/auditor menelaah dan menandatangani).
4. **Ambang frekuensi**: ditetapkan pemilik, mis. "BG tidak lebih dari N kali/bulan tanpa persetujuan
   pengurus" (N = keputusan pemilik; usulan awal N=3).

### 3.4 Saat staf cuti / berhenti (SLA yang bisa dieksekusi)

- **Cuti ≤ 5 hari kerja**: tidak ada perubahan peran. Bila langkah maker-checker dibutuhkan dan lawan
  tidak ada → pakai BG + buku + laporan H+1 (3.3). **Jangan** berbagi kata sandi atau memakai akun orang
  yang cuti (Attribusi audit rusak).
- **Cuti > 5 hari kerja atau berhenti**: dalam **1 hari kerja**:
  1. Pastikan calon pengganti **sudah** memegang `platform.user.manage` (beri `ops_admin` lebih dulu);
     tanpa itu `disable-user` akan ditolak `last_admin` (fakta `auth_service.nim:536`).
  2. `kran-api --role=ctl disable-user --username=<orang>` (mencabut semua sesi — `runbooks/pilot-provisioning.md:66`).
  3. Pindahkan peran esensial ke pengganti lewat `ctl assign-role` (teraudit; **perhatikan konflik**:
     `assign-role` yang melahirkan pasangan tersemai akan ditolak `sod_conflict`).
  4. Tidak menyerahkan kata sandi; akun baru, kata sandi baru (`must_change_password = true`).

### 3.5 Opsi ditolak + alasan | Biaya | Risiko | Yang ditandatangani

- **Ditolak — "1 akun `platform_admin` untuk semua orang".** SoD nol; alur maker-checker macet
  (`self_approval`); audit tak bisa membedakan operator. *Alasan:* melawan tujuan K-1/K-2 (D-131).
- **Ditolak — "2 akun + break-glass sebagai keadaan tetap".** Tiap operasi ganda jadi override → override
  menjadi norma, kontrol hilang. *Alasan:* break-glass harus pengecualian, bukan jalur utama.
- **Ditolak — "berbagi satu kata sandi antar staf".** Menghapus atribusi audit (siapa berbuat apa tak
  terbukti). *Alasan:* audit `platform.audit_log` jadi tak bermakna.
- **Biaya implementasi:** **prosedur saja (0 kode)** — buku break-glass + SLA + template laporan. Opsional
  (bukan sekarang): parameter `platform.sod.break_glass.enabled` (default `false`) + izin tersendiri +
  `NEEDS-COMPLIANCE-REVIEW` bila pemilik ingin memaksanya di sistem.
- **Risiko bila tidak diputuskan:** produksi terus memakai `platform_admin` harian → seluruh pasangan SoD
  yang sudah disemai **tidak efektif** (O-102), dan tidak ada satu pun catatan pemakaian override.
- **Yang ditandatangani pemilik:** (a) minimum = **3 operator harian** (target 4) + 1 BG tersegel;
  (b) identitas pemegang/BG; (c) ambang frekuensi N + kewajiban laporan H+1; (d) SLA 1 hari kerja untuk
  berhenti; (e) larangan `platform_admin` sebagai login harian.

---

## 4. K-4 — Format bukti maker-checker top-up vault

### 4.1 Field wajib (yang sudah ada — jangan tambah kolom dulu)

Bukti kanonik = satu baris `teller.vault_topup_request`. Field wajib dan perannya:

| Field | Wajib | Bukti apa |
|---|---|---|
| `request_id` | ya (sistem) | **identitas dokumen bukti** (dipakai sebagai nomor arsip) |
| `branch_id` | ya | cabang (vault per cabang) |
| `amount` | ya | nominal fisik |
| `source_account` | ya (FK `ledger.coa_account`) | akun lawan GL (jenis sumber dana) |
| `note` | **ya**, 1–200 karakter | **alasan + sumber dana + nomor referensi bukti fisik** |
| `requested_by` / `decided_by` / `decided_at` | ya | maker ≠ checker (dua **user id**), waktu keputusan |
| `decision_note` | pada REJECT | alasan penolakan |
| `journal_id` | pada APPROVED | tautan ke `ledger` |

### 4.2 Format `note` (template, muat ≤200 karakter)

Karena `note` hanya 200 karakter dan bukti fisik tidak bisa diunggah, gunakan bentuk tiga bagian:

```
[<JENIS SUMBER>] <jenis bukti> <nomor referensi> | <tujuan singkat>
```

Contoh sah (ilustrasi, bukan data nyata):
- `[BANK] slip setoran 2026-10-24/BCA/123456 | setoran modal kas cabang`
- `[PENGURUS] kuitansi 2026-10-24/KW-07 | penyetoran kas pengurus ke vault`

Aturan: `note` **wajib** memuat (1) jenis sumber dana, (2) nomor referensi bukti fisik/digital, (3)
tujuan. Detail yang tidak muat ditulis di bukti fisik dan **hanya** nomor referensinya masuk `note`.
Tidak memuat nomor referensi → **checker menolak**. (Bila pemilik ingin field terstruktur, opsi kolom
baru ada di 4.6 — opsional.)

### 4.3 Siapa menyimpan bukti fisik/digital

- **Bukti fisik asli** (slip bank setoran/penarikan, kuitansi, bukti setor ke rekening institusi) disimpan
  di **Berkas Bukti Kas cabang** (berkas per cabang, per bulan).
- **Salinan digital** (foto/scan) disimpan di folder bukti institusi yang ditunjuk (di luar DB). DB **tidak**
  menyimpan berkas.
- **Custodian:** teller/kasir cabang menyimpan berkas fisik; `cash_admin`/`ops_admin` menyimpan salinan
  digital. Pemilik menunjuk custodian tetap (kolom "yang menandatangani" di 3.5).

### 4.4 Bagaimana bukti ditandai pada data

- **Di DB:** `request_id` adalah nomor dokumen; tulis `request_id` (atau label singkat) pada slip fisik;
  tulis nomor referensi slip ke `note`. Tautan GL = `journal_id`.
- **Tanpa kolom baru** untuk pilot (cukup `note` + `journal_id`). Opsi kolom `evidence_type`/`evidence_ref`
  dicatat sebagai usulan Fase berikutnya bila volume bukti meningkat (4.6).

### 4.5 Yang diperiksa checker **sebelum** menyetujui (checklist)

1. `amount` pada pengajuan **sama** dengan nominal pada bukti fisik/digital (approve = apa adanya; tidak
   ada edit).
2. `source_account` benar (rekening bank/modal yang benar), **bukan** akun vault itu sendiri (sudah ditolak
   sistem — handler:115,328), akun ASSET aktif **postable**.
3. `note` lengkap: jenis sumber + nomor referensi + tujuan; cocok dengan bukti fisik.
4. Cabang benar (`branch_id` = cabang yang dituju).
5. Pengaju adalah **orang lain** (bukan hanya akun lain) — verifikasi manusia, bukan sekadar sistem.
6. Periode buku business-date **OPEN** (kalau tidak, ditolak `period_closed`).
7. Ada perbedaan/keraguan → **tolak** dengan `decision_note` (wajib); jangan setujui sebagian.

### 4.6 Retensi (`NEEDS-COMPLIANCE-REVIEW`)

- **Data DB + audit + jurnal: disarankan permanen / tidak dihapus.** Ledger sudah immutable dan audit
  append-only; menghapus pengajuan/`journal_id` akan memutus jejak. Kebijakan retensi formal platform
  **belum ada** (O-093/O-004) → tandai `NEEDS-COMPLIANCE-REVIEW`.
- **Bukti fisik di Berkas Bukti Kas: usulan angka pilot = 10 tahun; `NEEDS-COMPLIANCE-REVIEW`.** Spec §4
  REG-007 (UU 8/1997, retensi dokumen keuangan) bertanda `V?` **belum terverifikasi** — angka ini
  **usulan kepatuhan**, bukan kutipan hukum; compliance harus memvalidasi sebelum data anggota nyata.
- **Yang ditandatangani pemilik:** template `note`, custodian bukti, dan **angka retensi** (ditandai
  `NEEDS-COMPLIANCE-REVIEW` sampai compliance memvalidasi).

### 4.7 Opsi ditolak | Biaya | Risiko

- **Ditolak — tabel lampiran / unggah dokumen sekarang.** Fitur besar (storage, karantina, PII, backup);
  tidak perlu untuk pilot. *Alasan:* KISS/ADR.
- **Ditolak — simpan scan di dalam DB (`bytea`).** Membengkakkan DB/backup + risiko PII. *Alasan:* di luar
  pola repo, tak ada kebutuhan.
- **Ditolak — andalkan `note` tanpa berkas fisik.** `note` ≤200 karakter tidak bisa menjadi bukti yang
  dapat diverifikasi. *Alasan:* bukti harus punya rujukan nyata.
- **Biaya:** prosedur + berkas (**0 kode**). Opsional kecil bila pemilik ingin kolom terstruktur:
  ~1 migrasi + beberapa field handler (`evidence_type`/`evidence_ref`).
- **Risiko bila tidak diputuskan:** bukti sumber dana tidak dapat diverifikasi → temuan audit; skema
  "kas disuntik untuk menutup selisih" (O-098) hanya tertutup sebagian (maker-checker ada, bukti lemah).

---

## 5. K-8 — Bolehkah `teller` memakai jalur top-up vault?

### 5.1 Rekomendasi tegas

**Tidak. `teller` TIDAK boleh memegang `teller.vault.submit`, dan mutlak TIDAK boleh memegang
`teller.vault.approve`.** Pertahankan 0035 apa adanya.

- `teller` hari ini memang **tidak** memegang keduanya (fakta 0035:63-78). Rekomendasi = **jangan diubah**.

### 5.2 Alasan (SoD)

- `teller` adalah pemegang **laci** (sesi, transaksi tunai, hitung kas). Yang menyuntik isi vault adalah
  `cash_admin`/`ops_admin`. Bila `teller` bisa **submit**, orang yang lacinya kurang bisa **mengajukan**
  injeksi kas agar selisihnya tampak tertutup oleh setoran yang "formal" — tepat pola O-098.
- `teller` sudah berpasangan konflik dengan `cash_admin` (nice-to-have, tersemai). Memberi `teller`
  **approve** berarti penyetuju penambahan kas adalah orang yang mengendalikan/menghitung laci → kontrol
  kedua kehilangan makna; pasangan `cash_admin`↔`teller` harus dinaikkan menjadi **wajib** bila ini
  dilakukan.
- Pemisahan fungsi: **penyediaan kas** (vault) harus independen dari **operasi kas** (laci). Pilot kecil
  tidak mengubah prinsip ini; ia hanya menuntut jumlah orang (K-3), bukan pelebaran peran.

### 5.3 Konsekuensi SoD

- **Status quo (rekomendasi):** tidak ada perubahan pasangan; `cash_admin`↔`teller` cukup sebagai
  nice-to-have (efek: satu akun tak boleh kedua-duanya).
- **Opsi (b) yang ditolak:** bila `teller` diberi submit+approve, maka `cash_admin`↔`teller` **wajib**
  ditegakkan **dan** `ledger_admin`↔`teller` naik prioritas; menambah kerumitan tanpa menambah kontrol.
- **Bila suatu saat teller benar-benar harus mengorigini pengajuan:** hanya lewat **break-glass** (akun BG
  sebagai penyetuju, berbeda user id) + buku + laporan H+1 (3.3) — bukan dengan memperluas peran `teller`.

### 5.4 Opsi ditolak | Biaya | Risiko

- **Ditolak — opsi (b): `teller` boleh submit dengan maker-checker.** Pengaju masih pihak yang mengelola
  laci → insentif menyuntik kas untuk menutup selisih tetap ada. *Alasan:* melemahkan O-098.
- **Ditolak — `teller` boleh approve.** Membatalkan maker-checker (penyetuju = pengguna kas). *Alasan:*
  SoD tanpa makna.
- **Biaya:** **0 kode / 0 migrasi** (cukup tidak mengubah 0035). To make it structurally impossible, any
  future migration that would add `teller` to `teller.vault.submit`/`approve` must be rejected on sight or
  carry an explicit owner decision.
- **Risiko bila tidak diputuskan:** tekanan operasional ("teller saja yang ada di cabang") bisa menambah
  izin ini lewat migrasi tanpa keputusan tertulis → celah O-098 terbuka kembali.
- **Yang ditandatangani pemilik:** konfirmasi `teller` **tanpa** `submit` **dan tanpa** `approve`; dan bila
  terpaksa, lewat break-glass + laporan.

---

## 6. Ringkasan yang perlu ditandatangani pemilik

| Item | Keputusan pemilik |
|---|---|
| **K-3** | Minimum **3 operator harian** (target 4) + 1 akun break-glass tersegel; tata letak O1–O4; larangan `platform_admin` login harian; ambang frekuensi N; SLA 1 hari kerja untuk berhenti; format Buku Break-glass + laporan H+1. |
| **K-4** | Template `note` (jenis sumber + nomor referensi + tujuan); custodian bukti fisik/digital; **angka retensi** (usulan 10 tahun, `NEEDS-COMPLIANCE-REVIEW`); checklist checker. |
| **K-8** | `teller` **tidak** memegang `teller.vault.submit` maupun `teller.vault.approve` (status quo 0035). |

## 7. Penanda yang wajib menyertai (bukan keputusan)

- **`NEEDS-COMPLIANCE-REVIEW`**: angka retensi bukti fisik (REG-007 `V?`), dan semua pemetaan akun kas
  (`101.1`/`101.2`/`101.9`, REG-011 `V?`) — konsisten dengan D-132/O-097.
- **`HUMAN-REVIEW-REQUIRED`** (AGENTS.md §8): setiap perubahan yang menyentuh mutasi saldo vault/jurnal.
- **Tidak ada angka regulasi yang dikarang.** Bila compliance menetapkan angka berbeda, cukup ubah
  parameter/prosedur, bukan kode (`task` limits menyusul di K-5/O-099).
