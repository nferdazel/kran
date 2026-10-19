# KRAN Indonesia — PRD & Technical Specification

| | |
|---|---|
| **Repo** | `kran` (monorepo) |
| **Status** | Draft v0.1 |
| **Target segmen** | Koperasi (KSP/USP/KSPPS), BPR, BPRS, BMT |
| **Stack** | PostgreSQL · Nim (backend) · SvelteKit + TypeScript (frontend) |
| **Prinsip** | Clean Architecture · DRY · KISS · Reactive |
| **Pilar non-fungsional** | Modular · Parameter database-driven · Day-close framework · Dark/Light · i18n · a11y · Compliance-by-design |

> **Catatan jujur soal "full compliance".** Software tidak bisa "menjamin" compliance sendirian. Yang bisa dilakukan sistem: (1) menerjemahkan regulasi menjadi *kontrol yang bisa diaudit* (rule, parameter, laporan, audit trail), (2) menyimpan **Regulatory Register** yang ter-versi dan terhubung ke fitur + test, (3) membuat perubahan regulasi cukup lewat **parameter/regulatory pack**, bukan ubah kode. Daftar regulasi di dokumen ini adalah **hasil analisis awal dari pengetahuan saya dan WAJIB diverifikasi** (nomor, pasal, dan masih berlaku/tidaknya) oleh compliance officer / konsultan hukum sebelum jadi acuan. Setiap item ditandai status verifikasi di §4.

---

## Daftar Isi

1. [Ringkasan & Tujuan](#1-ringkasan--tujuan)
2. [Scope](#2-scope)
3. [Persona & Kebutuhan Per Segmen](#3-persona--kebutuhan-per-segmen)
4. [Regulatory Compliance Analysis](#4-regulatory-compliance-analysis)
5. [Prinsip Arsitektur](#5-prinsip-arsitektur)
6. [Arsitektur Sistem](#6-arsitektur-sistem)
7. [Struktur Monorepo](#7-struktur-monorepo)
8. [Modul & Bounded Context](#8-modul--bounded-context)
9. [Fondasi Data (PostgreSQL)](#9-fondasi-data-postgresql)
10. [Parameter Framework (Database-Driven)](#10-parameter-framework-database-driven)
11. [Day-Close Framework (EOD/EOM/EOY)](#11-day-close-framework-eodeomeoy)
12. [Backend Spec (Nim)](#12-backend-spec-nim)
13. [API Design](#13-api-design)
14. [Frontend Spec (SvelteKit + TS)](#14-frontend-spec-sveltekit--ts)
15. [Theming (Dark/Light)](#15-theming-darklight)
16. [Internationalization (i18n)](#16-internationalization-i18n)
17. [Accessibility (a11y)](#17-accessibility-a11y)
18. [Security & Data Protection](#18-security--data-protection)
19. [Reactive Architecture](#19-reactive-architecture)
20. [Testing Strategy](#20-testing-strategy)
21. [CI/CD (Ikuti Pola Existing)](#21-cicd-ikuti-pola-existing)
22. [Observability & Operasional](#22-observability--operasional)
23. [Roadmap & Milestone](#23-roadmap--milestone)
24. [Risiko](#24-risiko)
25. [ADR (Architecture Decision Records) Awal](#25-adr-awal)
26. [Open Questions & Asumsi](#26-open-questions--asumsi)
27. [Lampiran](#27-lampiran)

---

## 1. Ringkasan & Tujuan

### 1.1 Problem
Lembaga keuangan mikro/kecil di Indonesia (koperasi, BPR/BPRS, BMT) umumnya memakai KRAN yang mahal, kaku, atau aplikasi ad-hoc yang tidak siap audit. Perubahan regulasi (rate, PPAP, pelaporan, perpajakan) sering berarti *patch kode*, bukan konfigurasi.

### 1.2 Tujuan Produk
Membangun **KRAN standar, modular, open-architecture** yang:

1. Melayani 3 rumpun institusi (koperasi, BPR/BPRS, BMT) dari **satu codebase** lewat *product & regulatory pack*.
2. **Compliance-by-design**: kontrol regulasi jadi first-class (parameter, rule, laporan, audit trail, traceability).
3. **Semua nilai bisnis di database** (rate, limit, fee, kalender, GL mapping, ambang kolektibilitas, dst.) — ditegakkan oleh tooling, bukan sekadar konvensi.
4. **Day-close framework** (EOD/EOM/EOY) yang idempotent, resumable, bisa disimulasikan, dan extensible per modul.
5. Mudah dipelajari & di-enhance: modul kecil, batas jelas, template modul, dokumentasi hidup.
6. UI modern: **dark/light**, **i18n**, **a11y (WCAG 2.2 AA)** sebagai fondasi, bukan afterthought.

### 1.3 Non-Goals (v1)
- Bukan super-app / mobile banking konsumen (disiapkan lewat API & channel adapter).
- Bukan payment switch. Integrasi BI-FAST/QRIS/switching = adapter fase lanjut.
- Bukan treasury/trading/valas kompleks.
- Bukan multi-tenant SaaS pada v1 (lihat ADR-005).

### 1.4 Success Metrics
| Metrik | Target awal |
|---|---|
| Semua nilai bisnis dari DB | 0 *magic number* bisnis di layer domain (dicek CI) |
| EOD 100k rekening simpanan + 50k pinjaman | < 30 menit (hardware entry-level, dapat diubah via benchmark) |
| Perubahan rate/fee/limit | 0 deploy, cukup maker-checker |
| a11y | 0 pelanggaran axe *serious/critical* di CI; seluruh alur utama bisa keyboard-only |
| Onboarding developer | Modul baru "hello world" end-to-end < 1 hari dari template |
| Traceability | 100% requirement regulasi aktif ter-map ke fitur + test |

---

## 2. Scope

### 2.1 In-scope v1 (per fase di §23)
- **Platform**: auth, RBAC + branch scoping, maker-checker, audit, parameter, kalender, workflow, notifikasi, dokumen, i18n catalog.
- **Party/CIF**: nasabah/anggota perorangan & badan, KYC/CDD/EDD, risk rating, screening.
- **Product Factory**: katalog produk parametrik (simpanan, deposito, pembiayaan/kredit, syariah).
- **Deposit**: simpanan pokok/wajib/sukarela (koperasi), tabungan, deposito, wadiah/mudharabah (syariah).
- **Lending**: kredit & pembiayaan (konvensional + akad syariah), jadwal angsuran, kolektibilitas, PPAP/CKPN, restrukturisasi, hapus buku.
- **Teller & Cash**: sesi teller, vault, setoran/penarikan/pemindahbukuan, cetak buku tabungan & slip.
- **General Ledger**: COA, double-entry, posting rule dari event, periode, trial balance, laporan keuangan.
- **Day-Close Engine**: EOD/EOM/EOQ/EOY.
- **Compliance & Reporting**: APU-PPT, laporan regulator, pajak, laporan RAT/SHU (koperasi), rasio kesehatan.
- **Admin & Ops**: konfigurasi, monitoring batch, backup/restore tooling.

### 2.2 Out-of-scope v1 / Adapter fase lanjut
Mobile/internet banking, ATM/EDC switching, BI-FAST/SNAP, QRIS, e-money, agen (laku pandai), credit scoring ML, SLIK real-time (v1: file/batch export + adapter interface).

---

## 3. Persona & Kebutuhan Per Segmen

### 3.1 Persona
| Persona | Kebutuhan inti |
|---|---|
| Teller/Kasir | Transaksi cepat, keyboard-first, cetak buku/slip, tutup kas |
| CS/Account Officer | Onboarding anggota/nasabah, KYC, pengajuan pembiayaan |
| Analis/Komite Kredit | Scoring sederhana, workflow approval berjenjang |
| Supervisor/Kepala Cabang | Maker-checker, override terkontrol, monitoring |
| Akunting | Jurnal, closing, laporan keuangan |
| Compliance/APU-PPT Officer | Screening, alert, STR/CTR, evidence |
| Auditor Internal/Eksternal | Audit trail read-only, jejak perubahan parameter |
| Pengawas Syariah (DPS) | Mapping produk↔fatwa, review akad & distribusi bagi hasil |
| Pengurus/Pengawas Koperasi | SHU, RAT, rasio kesehatan |
| Admin Sistem | Parameter, user, role, monitoring batch |

### 3.2 Perbedaan Per Segmen (dikelola lewat *Segment Pack*)
| Aspek | Koperasi (KSP/USP) | BPR | BPRS | BMT (umumnya KSPPS) |
|---|---|---|---|---|
| Entitas pelanggan | **Anggota** (wajib keanggotaan) | Nasabah | Nasabah | Anggota |
| Simpanan | Pokok, wajib, sukarela | Tabungan, deposito | Wadiah/mudharabah | Wadiah/mudharabah + pokok/wajib |
| Pembiayaan | Pinjaman | Kredit | Murabahah, mudharabah, musyarakah, ijarah, qardh | Idem BPRS |
| Laba | **SHU** + RAT | Laba/rugi bank | Laba/rugi + bagi hasil | SHU + bagi hasil |
| Regulator utama | Kemenkop UKM & OJK (sesuai ketentuan transisi sektor) | OJK | OJK + DSN-MUI | Kemenkop + DPS/DSN-MUI + OJK (sesuai ketentuan) |
| Pelaporan | Laporan koperasi, penilaian kesehatan | Laporan bulanan/berkala BPR, tingkat kesehatan | Idem + syariah | Laporan koperasi syariah |
| Pengawas syariah | — | — | **DPS** wajib | DPS/DPS-setara |

---

## 4. Regulatory Compliance Analysis

> **Status verifikasi**: `V?` = perlu verifikasi nomor/pasal/versi terkini · `V!` = sangat sensitif perubahan, wajib cek ke sumber resmi · Tidak ada tanda = relatif stabil tapi tetap diverifikasi saat implementasi. **Semua item ini harus dicek ulang sebelum jadi requirement final.**

### 4.1 Regulatory Register (dikelola di sistem juga — lihat §4.4)

#### A. Lintas segmen
| ID | Regulasi (analisis awal) | Dampak ke sistem | Status |
|---|---|---|---|
| REG-001 | **UU 4/2023 tentang Pengembangan dan Penguatan Sektor Keuangan (P2SK)** | Payung baru sektor keuangan, termasuk penguatan pengaturan/pengawasan koperasi simpan pinjam & BPR; masa transisi | V! |
| REG-002 | **UU 27/2022 Pelindungan Data Pribadi (PDP)** | Consent, hak subjek data, retensi, enkripsi, notifikasi kebocoran (batas waktu 3×24 jam), DPO, data subject request | V? |
| REG-003 | **UU 8/2010 PP-TPPU** & turunannya | Kontrol APU-PPT, CTR/STR ke PPATK, retensi dokumen | V? |
| REG-004 | **POJK APU-PPT-PPSPM untuk PJK sektor jasa keuangan** (pengganti POJK 12/2017; kemungkinan POJK 8/2023) | CDD/EDD, PEP, screening DTTOT/DPPSPM, risk rating, pelaporan | V! |
| REG-005 | **UU ITE (11/2008 jo. perubahannya)** & **PP 71/2019 PSTE** | Tanda tangan/dokumen elektronik, keamanan sistem elektronik | V? |
| REG-006 | **POJK Pelindungan Konsumen dan Masyarakat di Sektor Jasa Keuangan** (kemungkinan POJK 22/2023) | Transparansi produk, penanganan pengaduan (SLA), disclosure biaya/bunga | V? |
| REG-007 | **UU 8/1997 Dokumen Perusahaan** | Retensi dokumen keuangan (umumnya 10 tahun) → param retensi + arsip | V? |
| REG-008 | **Ketentuan perpajakan** (PPh final atas bunga/bagi hasil, PPN atas fee tertentu, bukti potong, AEOI/CRS-FATCA bila relevan) | Perhitungan & bukti potong pajak, laporan | V! |
| REG-009 | **Ketentuan LPS** (penjaminan simpanan, tingkat bunga penjaminan) & transisi penjaminan koperasi di P2SK | Rate penjaminan sebagai parameter; flag simpanan layak dijamin; laporan | V! |
| REG-010 | **Ketentuan Dukcapil** (verifikasi NIK/e-KTP) | Adapter verifikasi identitas | V? |
| REG-011 | **Standar akuntansi** (SAK EP dan ketentuan akuntansi sektoral; PSAK/SAK Syariah untuk akad syariah) | COA, posting rule, laporan keuangan, pengakuan margin/bagi hasil | V! |

#### B. Koperasi (konvensional)
| ID | Regulasi | Dampak | Status |
|---|---|---|---|
| REG-101 | **UU 25/1992 Perkoperasian** (diubah via UU Cipta Kerja & turunannya) | Keanggotaan, simpanan pokok/wajib, SHU, RAT, cadangan | V? |
| REG-102 | **PP tentang kemudahan/pelindungan koperasi & UMKM** (PP 7/2021 dan turunan) | Persyaratan badan hukum & kegiatan | V? |
| REG-103 | **Permenkop tentang Usaha Simpan Pinjam Koperasi** (terbaru; kemungkinan Permenkop 8/2023) | Batas kegiatan, rasio, perizinan, pelaporan, BMPP | V! |
| REG-104 | **Permenkop penilaian kesehatan KSP/USP** | Perhitungan skor kesehatan (permodalan, aset, manajemen, efisiensi, likuiditas, kemandirian, jatidiri) | V! |
| REG-105 | **Pengaturan/pengawasan KSP oleh OJK** sesuai P2SK dan ketentuan transisi | Pelaporan ke OJK, kontrol sektor jasa keuangan | V! |

#### C. BPR
| ID | Regulasi | Dampak | Status |
|---|---|---|---|
| REG-201 | **UU Perbankan (UU 7/1992 jo. 10/1998) & perubahan via P2SK** | Kegiatan usaha, rahasia bank | V? |
| REG-202 | **POJK terkait BPR/BPRS (kegiatan usaha, kelembagaan, penguatan/konsolidasi)** (mis. POJK 7/2024 – verifikasi) | Batas kegiatan, permodalan | V! |
| REG-203 | **KPMM/CAR, BMPK (Legal Lending Limit), ATMR** | Kalkulasi rasio, kontrol limit di pemberian kredit | V! |
| REG-204 | **Kualitas aset & PPAP/CKPN** (kolektibilitas 1–5, ketentuan penyisihan) | Penentuan kolektibilitas, PPAP, parameter persentase | V! |
| REG-205 | **POJK penyelenggaraan TI oleh BPR/BPRS** (kemungkinan POJK 19/2023) | DR/BCP, manajemen perubahan, audit trail, vendor mgmt, tata kelola TI | V! |
| REG-206 | **Tingkat Kesehatan BPR (RBBR)** | Perhitungan profil risiko, GCG, rentabilitas, permodalan | V! |
| REG-207 | **Pelaporan BPR (LBPR/laporan berkala, SLIK)** | Laporan terstruktur ke OJK, format & jadwal sebagai parameter | V! |

#### D. BPRS & BMT/KSPPS
| ID | Regulasi | Dampak | Status |
|---|---|---|---|
| REG-301 | **UU 21/2008 Perbankan Syariah** | Prinsip syariah, DPS, pemisahan dana | V? |
| REG-302 | **Fatwa DSN-MUI** (murabahah, mudharabah, musyarakah, ijarah, wadiah, qardh, wakalah, ta'zir/ta'widh, dll.) | Katalog akad, perilaku perhitungan & denda, dana kebajikan | V! |
| REG-303 | **Peraturan pembiayaan syariah oleh koperasi (KSPPS/USPPS)** (mis. Permenkop 16/2015 dan perubahannya) | Pembiayaan BMT berbasis akad | V! |
| REG-304 | **Ketentuan DPS** (komposisi, opini, laporan pengawasan) | Modul review DPS, mapping produk↔fatwa | V? |
| REG-305 | **Distribusi bagi hasil (nisbah, revenue/profit sharing), pengelolaan dana non-halal, zakat/ZIS** | Engine bagi hasil di EOM, laporan sumber/penggunaan dana kebajikan | V! |

### 4.2 Mapping Regulasi → Kontrol Sistem (ringkas)

| Domain kontrol | Mekanisme di sistem | Modul |
|---|---|---|
| KYC/CDD/EDD | Workflow onboarding + risk rating terparameter + dokumen + re-KYC periodik via day-close | `party`, `compliance` |
| Screening DTTOT/DPPSPM/PEP | Screening saat onboarding, transaksi, dan batch harian; list dikelola sebagai data | `compliance` |
| CTR/STR | Rule transaksi tunai/mencurigakan (threshold = parameter), alert queue, case mgmt | `compliance` |
| Kolektibilitas & PPAP | Task day-close: update DPD → re-grade → hitung PPAP; persentase = parameter | `lending`, `daycloser` |
| BMPK/BMPP | Check di use-case pemberian pembiayaan; limit = parameter dari modal | `lending`, `compliance` |
| Pajak bunga/bagi hasil | Posting rule + pajak terparameter (tarif, ambang, NPWP/non-NPWP) | `deposit`, `tax` |
| Pelaporan regulator | Report definition ter-versi (SQL view + mapping kode laporan) + jadwal | `reporting` |
| Rahasia bank/data pribadi | Field-level encryption, masking, purpose-based access, audit akses | `platform` |
| Segregation of Duties | Maker-checker, role conflict matrix, branch scoping | `platform` |
| Retensi | Policy retensi per tipe data = parameter; arsip partisi | `platform` |
| Syariah | Contract template per akad, nisbah, pemisahan pendapatan non-halal | `sharia`, `lending`, `deposit` |
| SHU/RAT (koperasi) | Perhitungan SHU parametrik (jasa simpanan vs jasa usaha) saat EOY | `coop`, `daycloser` |

### 4.3 Segment & Regulatory Packs
Setiap segmen dikirim sebagai **pack** berisi *seed data ter-versi*: parameter default, COA template, produk template, definisi laporan, rule compliance, template akad. Pack dipasang via migrasi seed idempotent:

```
packs/
  base/            # parameter & COA inti, kalender, role template
  koperasi/        # keanggotaan, simpanan pokok/wajib, SHU, laporan koperasi
  bpr/             # kolektibilitas, PPAP, BMPK, laporan BPR
  syariah/         # akad, nisbah, DPS, dana kebajikan
  bmt/             # gabungan koperasi + syariah
```
Pack bisa di-upgrade (mis. regulasi berubah) tanpa menyentuh kode: pack baru = parameter baru dengan `effective_from` baru + maker-checker.

### 4.4 Regulatory Register di Dalam Sistem
Tabel `compliance.regulation` + `compliance.requirement` + `compliance.requirement_control` (link ke parameter key, laporan, test ID, modul). Fungsi:
- Auditor bisa melihat: *"POJK X pasal Y → dikontrol oleh fitur/parameter/laporan Z, dibuktikan oleh test T"*.
- CI gagal jika requirement `active` tidak punya `control` atau test (traceability gate).

### 4.5 Rekomendasi Proses (di luar kode)
1. Tunjuk **Compliance Owner** (internal/konsultan) untuk memvalidasi register ini per segmen.
2. Siapkan **due diligence vendor TI** — banyak BPR/BPRS wajib menilai penyedia sistem; siapkan dokumen (arsitektur, DR, pen-test, SLA, escrow source code bila diminta).
3. Rencanakan **UAT bersama pengguna nyata** tiap segmen sebelum klaim "siap".
4. Pelacakan perubahan regulasi: langganan sumber resmi (OJK, Kemenkop, DSN-MUI, DJP, PPATK).

---

## 5. Prinsip Arsitektur

### 5.1 Clean Architecture (aturan dependensi ke dalam)
```
interface (HTTP/CLI/SSE) ─┐
infrastructure (PG, mail,  ├──► application (use case, port) ──► domain (entity, VO, domain service, event)
  files, adapters)        ─┘
```
- **Domain**: murni, tanpa I/O, tanpa import framework/DB. Waktu & ID di-inject (`Clock`, `IdGen`).
- **Application**: use case orchestration, mendefinisikan **port** (interface repo, event bus, gateway).
- **Infrastructure**: implementasi port (Postgres repo, adapter eksternal).
- **Interface**: HTTP handler, mapper DTO↔use case. Tidak ada business logic.
- Aturan ditegakkan oleh **`tools/archcheck`** (script graf import) di CI — Nim tidak punya boundary linter bawaan.

### 5.2 DRY — secara pragmatis
- Shared kernel **kecil & stabil**: `Money`, `Quantity`, `Rate`, `BusinessDate`, `Result`, `Clock`, `Id`, `AuditContext`. Tidak boleh ada "utils" serbaguna.
- Duplikasi *kebetulan* (kode mirip tapi alasan berubah beda) **boleh**; duplikasi *pengetahuan* (aturan bisnis sama di dua tempat) **tidak boleh**.
- Kode generasi untuk hal repetitif: parameter key → konstanta Nim & tipe TS; OpenAPI → client TS; i18n key → tipe TS.
- Satu sumber kebenaran per hal: **kontrak API = OpenAPI**, **nilai bisnis = DB**, **skema = migrasi SQL**, **teks UI = i18n catalog**.

### 5.3 KISS
- **Modular monolith**, bukan microservices. Satu proses deploy, satu DB, banyak schema.
- Antrian & scheduler = **Postgres** (`FOR UPDATE SKIP LOCKED`, `LISTEN/NOTIFY`) — tanpa Kafka/Redis di v1.
- SQL eksplisit di repository (tanpa ORM berat). Query kompleks = SQL biasa + mapper tipe.
- Tambah dependensi hanya jika menghemat > ongkos pemeliharaan; catat di ADR.

### 5.4 Reactive
- **Backend**: event-driven internal (domain event → *transactional outbox* → subscriber), tidak ada side-effect di tengah transaksi.
- **Realtime ke UI**: WebSocket didorong dari `LISTEN/NOTIFY` + outbox (§19.1).
- **Frontend**: Svelte 5 runes (`$state`, `$derived`, `$effect`) + server-state cache yang di-invalidasi oleh event.
- Detail di §19.

### 5.5 Definition of "Modular & Gampang Dipelajari"
- Tiap modul punya **README + MODULE.md** (tujuan, bounded context, event yang dipublish/dikonsumsi, parameter key, tabel).
- **Template modul** (`tools/scaffold`) menghasilkan kerangka lengkap (domain/app/infra/iface + migrasi + test + i18n namespace + parameter seed).
- Modul hanya bicara lewat **public API modul** (`<module>/api.nim`) dan **event kontrak** — tidak boleh import internal modul lain (dicek archcheck).
- Konvensi nama & struktur identik antar modul (belajar satu = paham semua).

---

## 6. Arsitektur Sistem

### 6.1 Diagram Konteks
```
 [Browser: SvelteKit SPA/SSR] ──HTTPS/JSON + WS──► [API: Nim modular monolith] ──► [PostgreSQL]
                                                      │   ├─ module: platform, party, product, deposit, lending, ...
                                                      │   ├─ daycloser (orchestrator)
                                                      │   └─ outbox dispatcher / job runner (in-proc worker pool)
                                                      └──► Adapters (opsional): Dukcapil, SLIK, PPATK goAML, bank/switch, notif WA/SMS/email
```

### 6.2 Proses Runtime
| Proses | Peran | Catatan |
|---|---|---|
| `kran-api` | HTTP API + WebSocket | Stateless, bisa >1 instance |
| `kran-worker` | Job runner, outbox dispatcher, day-close executor | Binary sama, mode berbeda (`--role=worker`) |
| `postgres` | Sumber kebenaran | Primary + replica/backup (lihat §22) |
| `web` | SvelteKit (static build disajikan reverse proxy, atau node adapter) | Sesuai pola server existing |

> KISS: satu binary Nim dengan `--role=api|worker|migrate|all` mengurangi variasi deploy.

### 6.3 Modular Monolith: Aturan Batas
1. Setiap modul memiliki **schema Postgres sendiri** (`deposit.*`, `lending.*`, …). Tidak ada query lintas-schema dari modul lain — pakai public API modul atau read model/view yang sengaja diekspos.
2. Komunikasi sinkron antar modul: panggil `api.nim` modul tujuan (in-proc, tipe kuat).
3. Komunikasi asinkron: domain event lewat outbox (kontrak versi di `packages/contracts/events`).
4. Foreign key lintas schema hanya ke **ID referensi** (`party.party_id`) dan hanya jika disetujui di MODULE.md.

---

## 7. Struktur Monorepo

```
kran/
├─ apps/
│  ├─ api/                    # entrypoint Nim (api|worker|migrate|all)
│  └─ web/                    # SvelteKit app (TS)
├─ modules/                   # backend modules (Nim) — satu folder = satu bounded context
│  ├─ platform/               # auth, rbac, audit, param, calendar, workflow, notif, i18n-catalog
│  ├─ party/
│  ├─ product/
│  ├─ deposit/
│  ├─ lending/
│  ├─ teller/
│  ├─ ledger/                 # GL & accounting
│  ├─ daycloser/              # EOD/EOM/EOY orchestrator
│  ├─ compliance/             # APU-PPT, screening, regulatory register
│  ├─ reporting/
│  ├─ tax/
│  ├─ coop/                   # SHU, RAT, keanggotaan koperasi
│  ├─ sharia/                 # akad, nisbah, DPS, dana kebajikan
│  └─ <module>/
│     ├─ domain/              # entity, VO, domain service, event (pure)
│     ├─ application/         # use case, port (interface)
│     ├─ infrastructure/      # repo PG, adapter
│     ├─ interface/           # http handler, dto, route registration
│     ├─ migrations/          # SQL up/down milik modul
│     ├─ seeds/               # parameter & data default modul
│     ├─ tests/
│     ├─ api.nim              # PUBLIC API modul
│     └─ MODULE.md
├─ shared/
│  ├─ kernel/                 # Money, Rate, BusinessDate, Result, Clock, Id (kecil!)
│  └─ platform-lib/           # http server wrapper, pg pool, logging, config bootstrap
├─ packages/                  # sisi TS
│  ├─ contracts/              # OpenAPI (sumber kebenaran), event schema (JSON Schema), error code
│  ├─ api-client/             # hasil generate dari OpenAPI (jangan edit manual)
│  ├─ ui/                     # design system Svelte (token, komponen a11y-first)
│  ├─ i18n/                   # catalog pesan (id, en), tooling
│  └─ config/                 # eslint, tsconfig, prettier bersama
├─ packs/                     # segment & regulatory pack (seed ter-versi)
├─ tools/
│  ├─ archcheck/              # penegak batas arsitektur (Nim/py/ts, bebas)
│  ├─ paramgen/               # generate konstanta key param (Nim) & tipe (TS) dari definisi
│  ├─ lint-nomagic/           # deteksi magic number bisnis di domain
│  ├─ scaffold/               # template modul
│  └─ dbtools/                # migrate, seed, snapshot, anonymize
├─ docs/
│  ├─ adr/                    # keputusan arsitektur
│  ├─ regulatory/             # register + catatan analisis
│  └─ runbooks/               # operasional (EOD gagal, restore, dll.)
├─ ops/                       # artefak deploy — mengikuti pola existing (§21)
├─ .github/workflows/ci.yml   # verifikasi saja (pola existing, §21)
└─ README.md
```

**Tooling workspace**: `nimble` (workspace/task) untuk Nim; `pnpm` workspaces untuk TS; `Taskfile`/`just` sebagai *single entry* (`task check`, `task test`, `task build`) agar developer & CI memakai perintah sama.

---

## 8. Modul & Bounded Context

| Modul | Tanggung jawab | Event penting (publish) | Konsumsi |
|---|---|---|---|
| `platform` | Auth, session, RBAC, maker-checker, audit, **parameter**, kalender/business date, notifikasi, dokumen, outbox | `ParamChanged`, `UserLocked`, `BusinessDateOpened/Closed` | — |
| `party` | CIF, KYC, relasi, risk rating | `PartyOnboarded`, `PartyRiskChanged` | `ScreeningHit` |
| `product` | Product factory (parametrik, versi, effective-dated) | `ProductPublished` | `ParamChanged` |
| `deposit` | Rekening simpanan/deposito, bunga/bagi hasil, hold, dormant | `AccountOpened`, `DepositPosted`, `InterestAccrued` | `PartyOnboarded` |
| `lending` | Pengajuan, approval, pencairan, jadwal, DPD, kolektibilitas, PPAP, restruk, write-off | `LoanDisbursed`, `InstallmentDue`, `CollectibilityChanged` | `PartyRiskChanged` |
| `teller` | Sesi teller, vault, cash in/out, cetak | `CashTransactionPosted` | — |
| `ledger` | COA, jurnal double-entry, posting rule, periode, saldo, TB | `JournalPosted`, `PeriodClosed` | event bisnis (via posting rule) |
| `daycloser` | Orkestrasi EOD/EOM/EOQ/EOY (§11) | `DayCloseStarted/Completed/Failed` | semua modul mendaftarkan task |
| `compliance` | Screening, rule APU-PPT, case, STR/CTR, regulatory register | `ScreeningHit`, `CaseOpened` | `CashTransactionPosted`, `DepositPosted` |
| `reporting` | Definisi laporan, eksekusi, ekspor, jadwal | `ReportGenerated` | `PeriodClosed` |
| `tax` | Pajak bunga/bagi hasil, bukti potong | `TaxWithheld` | `InterestAccrued` |
| `coop` | Anggota, simpanan pokok/wajib, SHU, RAT | `SHUProposed`, `MembershipChanged` | `PeriodClosed(year)` |
| `sharia` | Katalog akad, nisbah, bagi hasil, dana kebajikan, DPS | `ProfitShareDistributed` | `PeriodClosed(month)` |

### 8.1 Pola Posting Otomatis ke GL
Modul bisnis **tidak** menulis jurnal langsung. Mereka memancarkan **accounting event** (`DepositPosted`, `LoanDisbursed`, `InterestAccrued`, …). `ledger` memiliki **posting rule (tabel, di-parameter-kan)** yang memetakan *event type + product + kondisi* → *template jurnal (debit/kredit via kode GL logis)*. Perubahan COA/mapping = parameter, bukan kode.

---

## 9. Fondasi Data (PostgreSQL)

### 9.1 Prinsip
1. **Versi PG ≥ 16**. Ekstensi: `pgcrypto`, `pg_trgm`, `btree_gist` (untuk exclusion constraint periode), opsional `pg_partman`.
2. **Uang** disimpan `NUMERIC(24,4)` (presisi untuk akrual); pembulatan sesuai parameter di batas (posting/laporan). Di Nim: tipe `Money` fixed-point integer (skala 10⁴) — tidak pernah `float`.
3. **Ledger immutable**: jurnal tidak di-UPDATE/DELETE; koreksi = jurnal pembalik (reversal) + jurnal baru. Dipaksa trigger + privilege.
4. **Saldo = turunan**: tabel saldo (`balance`) adalah *cache* yang bisa direkonstruksi dari ledger; rekonsiliasi harian jadi task day-close.
5. **Bitemporal untuk data penting**: `valid_from/valid_to` (efektif bisnis) + `recorded_at` (kapan dicatat). Parameter, produk, rate wajib effective-dated.
6. **Tiga jenis tanggal** dipisahkan tegas: `business_date` (tanggal buku), `value_date`, `recorded_at` (timestamptz teknis).
7. **Audit**: perubahan tabel master dan parameter direkam (trigger/aplikasi) ke `platform.audit_log` ber-*hash chain* (tamper-evident).
8. **ID**: UUIDv7 (terurut waktu) untuk PK internal; **nomor bisnis** (no. rekening, no. anggota) dibuat dari format parameter + sequence (dengan check digit).
9. **Partisi** tabel besar (`journal_line`, `audit_log`, `batch_*`) berdasarkan `business_date`/bulan.
10. **Row-Level Security** untuk branch scoping (opsional ketat, lihat §18).
11. **Migrasi**: SQL murni, *forward-only* + pola **expand/contract** (aman rolling deploy). Rollback = migrasi maju yang memperbaiki, kecuali yang terbukti reversibel.

### 9.2 Schema Awal (ringkas)
```
platform.*   : user, role, permission, role_permission, user_role, session, audit_log, outbox, inbox,
               param_definition, param_value, calendar, holiday, business_date, workflow_*, document, notification
party.*      : party, party_person, party_org, identity_doc, address, relation, kyc_profile, risk_rating
product.*    : product, product_version, product_param_binding
deposit.*    : account, account_balance, hold, interest_accrual, term_deposit
lending.*    : application, loan, schedule, installment, collateral, dpd_snapshot, collectibility, provision
teller.*     : teller_session, vault, cash_movement
ledger.*     : coa_account, posting_rule, journal, journal_line, period, balance_snapshot
daycloser.*  : batch_run, batch_task, batch_task_chunk, batch_lock, task_registry
compliance.* : regulation, requirement, requirement_control, screening_list, screening_hit, aml_rule, aml_alert, case
reporting.*  : report_def, report_run
coop.* / sharia.* / tax.* : sesuai modul
```

### 9.3 Contoh DDL Inti (acuan, bukan final)

```sql
-- Business date (per institusi, optional per cabang)
CREATE TABLE platform.business_date (
  scope_type   text NOT NULL DEFAULT 'INSTITUTION',   -- INSTITUTION | BRANCH
  scope_id     uuid,                                  -- null untuk institusi
  current_date date NOT NULL,
  state        text NOT NULL CHECK (state IN ('OPEN','CLOSING','CLOSED')),
  updated_at   timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (scope_type, COALESCE(scope_id,'00000000-0000-0000-0000-000000000000'))
);

-- Jurnal immutable, double-entry
CREATE TABLE ledger.journal (
  journal_id   uuid PRIMARY KEY,
  business_date date NOT NULL,
  value_date    date NOT NULL,
  source_event  text NOT NULL,         -- tipe accounting event
  source_ref    uuid NOT NULL,         -- id transaksi asal
  idempotency_key text NOT NULL UNIQUE,
  reversal_of   uuid REFERENCES ledger.journal(journal_id),
  recorded_at   timestamptz NOT NULL DEFAULT now()
) PARTITION BY RANGE (business_date);

CREATE TABLE ledger.journal_line (
  journal_id  uuid NOT NULL,
  line_no     int  NOT NULL,
  gl_account  text NOT NULL,
  branch_id   uuid NOT NULL,
  debit       numeric(24,4) NOT NULL DEFAULT 0 CHECK (debit  >= 0),
  credit      numeric(24,4) NOT NULL DEFAULT 0 CHECK (credit >= 0),
  CHECK ((debit = 0) <> (credit = 0)),
  PRIMARY KEY (journal_id, line_no)
);
-- Constraint trigger: SUM(debit) = SUM(credit) per journal (deferred), + larang UPDATE/DELETE.
```

---

## 10. Parameter Framework (Database-Driven)

### 10.1 Aturan Emas
> **Tidak ada nilai bisnis di dalam kode.** Rate, limit, fee, ambang, tarif pajak, kalender, hari-grace, persentase PPAP, format nomor rekening, mapping GL, template pesan transaksional, dsb. — semuanya berasal dari database dan dapat diubah lewat maker-checker, ter-audit, dan **effective-dated**.

Yang **boleh** di kode: konstanta teknis (timeout, ukuran buffer), invarian matematis (mis. 12 bulan/tahun, urutan hari), dan **default fallback yang terdokumentasi** (lihat 10.6).

### 10.2 Model Data

```sql
CREATE TABLE platform.param_definition (
  key            text PRIMARY KEY,                  -- 'lending.ppap.rate.kl' (namespace.modul.kategori.nama)
  module         text NOT NULL,
  value_type     text NOT NULL,                     -- integer|decimal|string|bool|json|enum|money|rate|date|duration
  json_schema    jsonb NOT NULL,                    -- validasi nilai (bentuk, min/max, enum)
  allowed_scopes text[] NOT NULL,                   -- GLOBAL, INSTITUTION, BRANCH, PRODUCT, SEGMENT, ROLE
  description_key text NOT NULL,                    -- kunci i18n untuk deskripsi & label
  regulatory_refs text[] NOT NULL DEFAULT '{}',     -- REG-204, dst
  sensitivity    text NOT NULL DEFAULT 'NORMAL',    -- NORMAL|CRITICAL (CRITICAL = 4-eyes + approval berjenjang)
  requires_approval boolean NOT NULL DEFAULT true,
  change_window  text,                              -- mis. hanya di luar jam batch
  since_version  text NOT NULL,
  deprecated     boolean NOT NULL DEFAULT false
);

CREATE TABLE platform.param_value (
  param_value_id uuid PRIMARY KEY,
  key            text NOT NULL REFERENCES platform.param_definition(key),
  scope_type     text NOT NULL,
  scope_id       text,                              -- null untuk GLOBAL
  value          jsonb NOT NULL,
  effective_from date NOT NULL,
  effective_to   date,                              -- null = terbuka
  status         text NOT NULL,                     -- DRAFT|PENDING|ACTIVE|SUPERSEDED|REJECTED
  maker          uuid NOT NULL,
  checker        uuid,
  reason         text NOT NULL,
  recorded_at    timestamptz NOT NULL DEFAULT now(),
  EXCLUDE USING gist (key WITH =, scope_type WITH =, COALESCE(scope_id,'') WITH =,
                      daterange(effective_from, effective_to, '[)') WITH &&)
         WHERE (status = 'ACTIVE')
);
```
- **Resolusi nilai** (urut spesifik → umum): `PRODUCT` → `BRANCH` → `INSTITUTION` → `SEGMENT` → `GLOBAL`. Pada `as_of` (business date). Aturan resolusi didefinisikan sekali di `platform/param` dan dipakai semua modul.
- **Snapshot per run**: day-close mengambil *parameter snapshot* di awal run (disimpan referensinya) agar hasil bisa direproduksi walau parameter berubah di tengah.

### 10.3 Akses di Kode (typed & generated)

Definisi param ditulis sebagai file deklaratif di tiap modul (`modules/<m>/seeds/params.yaml`):

```yaml
- key: lending.collectibility.dpd.kl
  type: integer
  scopes: [INSTITUTION, SEGMENT]
  schema: { minimum: 1, maximum: 365 }
  sensitivity: CRITICAL
  regulatory_refs: [REG-204]
  default_pack: { bpr: 91, koperasi: 91 }   # nilai awal di pack, BUKAN fallback kode
```

`tools/paramgen` menghasilkan:
- **Nim**: `const P_lending_collectibility_dpd_kl = ParamKey[int]("lending.collectibility.dpd.kl")` — key bertipe; pemakaian `params.get(P_..., asOf, scope)` mengembalikan `int`.
- **TS**: tipe + metadata untuk UI Parameter Admin (form otomatis dari JSON Schema).
- **SQL seed** ke `param_definition`.

```nim
# application layer (contoh)
let dpdKl = params.get(P_lending_collectibility_dpd_kl, asOf = bizDate, scope = loanScope)
```
Pemakaian string key mentah dilarang (lint).

### 10.4 Penegakan (Enforcement) — bukan sekadar konvensi

| Lapisan | Mekanisme |
|---|---|
| **Compile-time** | Hanya key hasil generate yang bisa dipakai (`ParamKey[T]` typed). Key tak terdaftar = error compile. |
| **Static lint (CI)** | `tools/lint-nomagic` memindai `domain/` & `application/`: literal numerik/ string bisnis (bukan whitelist teknis seperti 0, 1, 12, 100 untuk persen) → gagal. Anotasi eksplisit `# nomagic:ok <alasan>` untuk pengecualian, direview. |
| **Startup check** | Saat boot, semua key yang dirujuk kode (hasil generate) **harus** ada nilainya aktif utk scope yang wajib; jika tidak → proses menolak start (fail fast), kecuali mode setup awal. |
| **Schema validation** | Nilai divalidasi JSON Schema saat input, dan lagi saat dibaca (defense in depth). |
| **Governance** | Param `CRITICAL` = maker-checker + approver berjenjang + change window; semua perubahan masuk audit log + event `ParamChanged`. |
| **Cache & invalidasi** | Cache in-proc per business date; invalidasi lewat `LISTEN/NOTIFY` pada `ParamChanged`. |
| **Test** | Property test: perilaku modul berubah sesuai param (bukan nilai hardcode) → *mutation test* sederhana: ubah param di fixture, hasil harus berubah. |
| **Drift guard** | Job harian membandingkan `param_definition` di DB vs hasil generate (kode); beda → alert. |

### 10.5 Cakupan "Wajib Database-Driven" (checklist minimum)
- Rate bunga/margin/nisbah/ujrah, metode hitung (flat/efektif/anuitas/sliding), basis hari (act/360, 30/360, act/365), pembulatan.
- Limit transaksi, saldo minimum/maksimum, biaya (admin, provisi, administrasi, penalti/ta'zir), grace period.
- Ambang kolektibilitas (DPD), persentase PPAP/CKPN, tarif pajak & ambang, rate penjaminan LPS.
- Kalender, hari libur, hari kerja, cut-off time, fiscal year start.
- Format nomor (rekening, anggota, kontrak), check digit.
- COA & posting rule, kode laporan, mapping regulator.
- Threshold APU-PPT, scoring risiko, daftar negara risiko tinggi.
- Retensi, kebijakan password/sesi, parameter keamanan.
- Workflow approval (limit per level), role conflict matrix.
- Template notifikasi/cetakan (teks lewat i18n catalog + template).

### 10.6 Fallback
Tidak ada fallback diam-diam. Jika key tidak ditemukan → **error eksplisit** (`ParamNotFound`) yang menghentikan use case/ task, dengan pesan jelas ke operator. (Fallback hanya untuk konstanta teknis.)

### 10.7 UI Parameter Admin
Form dibangkitkan dari JSON Schema; tampil riwayat (timeline effective-dated), diff, impact preview ("N produk/rekening terdampak"), simulasi (dry-run pada data sampel), alur approval.

---

## 11. Day-Close Framework (EOD/EOM/EOY)

### 11.1 Tujuan
Satu **kerangka orkestrasi** — modul lain hanya *mendaftarkan task*, tidak membuat batch sendiri. Karakteristik: **idempotent, resumable, DAG-based, observable, simulatable, calendar-aware**.

### 11.2 Konsep

| Konsep | Penjelasan |
|---|---|
| **Business Date** | Tanggal buku sistem (`platform.business_date`). Transaksi memakai business date, bukan jam server. |
| **Day-Close Run** | Satu eksekusi penutupan untuk business date tertentu (institusi atau cabang). |
| **Close Level** | `EOD` selalu; `EOW` (opsional), `EOM`, `EOQ`, `EOY` ditambahkan otomatis oleh kalender. **Kaskade**: hari kerja terakhir bulan ⇒ EOD + EOM; hari terakhir tahun fiskal ⇒ EOD + EOM + (EOQ) + EOY. |
| **Task** | Unit kerja milik modul; punya scope level, dependensi, strategi chunking, pre/post-check. |
| **Chunk** | Potongan task (mis. 1000 rekening) → paralel & resumable. |
| **Gate** | Pemeriksaan wajib (pre-close/ post-close) yang bisa memblokir. |

### 11.3 State Machine

```
Business Date:  OPEN ──start──► CLOSING ──all required tasks OK──► CLOSED ──open next──► (date+1) OPEN
                                   │
                                   └─ fail ─► CLOSING (blocked, perlu resolusi; tidak lanjut ke tanggal berikut)

Run:   PLANNED → PRECHECK → RUNNING → POSTCHECK → COMPLETED
                      │         │           └──────► FAILED
                      └─► BLOCKED (gate gagal)   └─► PAUSED / RESUMED
Task:  PENDING → READY → RUNNING → SUCCEEDED | FAILED | SKIPPED(by rule) | CANCELED
Chunk: PENDING → RUNNING → SUCCEEDED | FAILED(retryable)
```

### 11.4 Kontrak Task (Nim, konseptual)

```nim
type
  CloseLevel* = enum clEOD, clEOW, clEOM, clEOQ, clEOY
  TaskKind* = enum tkPreCheck, tkProcess, tkPostCheck, tkReport

  DayCloseTask* = object
    id*: TaskId                      # "lending.accrue-interest"
    module*: string
    levels*: set[CloseLevel]         # {clEOD} atau {clEOM, clEOY}, dst
    kind*: TaskKind
    dependsOn*: seq[TaskId]          # DAG (siklus ditolak saat registrasi)
    critical*: bool                  # gagal => blok penutupan hari
    idempotency*: IdempotencyMode    # per (task, businessDate, entity)
    partition*: PartitionStrategy    # mis. byAccountRange(chunkSize ← param)
    requiredParams*: seq[ParamKeyRef]
    run*: proc(ctx: TaskContext, chunk: Chunk): Future[Result[TaskOutput, TaskError]]
    verify*: proc(ctx: TaskContext): Future[Result[void, TaskError]]   # post-condition/rekonsiliasi
```
- **Registrasi**: tiap modul memanggil `daycloser.register(task)` saat boot. Registry diekspor ke tabel `daycloser.task_registry` (untuk UI & audit).
- **Idempotency**: setiap task bekerja berdasarkan **checkpoint per entitas** (`last_processed_business_date`), sehingga run ulang tidak menggandakan posting, dan **catch-up multi-hari** (mis. setelah libur panjang / sistem mati) bekerja otomatis.
- **Chunk size, paralelisme, retry/backoff, timeout** semuanya parameter (§10).

### 11.5 Orkestrator
1. **Plan**: tentukan close level dari kalender (via parameter fiscal year & holiday), kumpulkan task, topological sort → DAG.
2. **Precheck gates** (contoh): semua sesi teller tutup & kas seimbang; tidak ada transaksi *pending approval*; rekening antar-kantor/suspense = 0 atau tercatat; tidak ada batch lain berjalan (advisory lock); versi parameter ter-snapshot.
3. **Freeze**: set business date `CLOSING` → transaksi online ditolak/antri sesuai kebijakan param (`daycloser.txn_policy_during_close`).
4. **Execute**: jalankan task siap secara paralel (worker pool), chunk-level checkpoint, event progress → realtime (WS).
5. **Postcheck gates**: rekonsiliasi (saldo subledger = GL; TB seimbang; jumlah akrual = jurnal), hasil disimpan sebagai bukti.
6. **Seal**: snapshot saldo & trial balance harian, hitung hash ringkasan run (tamper-evident).
7. **Rollover**: business date → hari kerja berikutnya (`OPEN`), publikasi `BusinessDateOpened`.

### 11.6 Katalog Task Standar (awal)

**EOD**
| Task | Modul | Catatan |
|---|---|---|
| Validasi pra-tutup (teller, pending, suspense) | platform/teller | Gate |
| Akrual bunga/bagi hasil harian simpanan | deposit/sharia | Basis hari & metode dari param |
| Akrual bunga/margin pembiayaan | lending | Termasuk pengakuan margin syariah |
| Generasi tagihan jatuh tempo, auto-debit | lending/deposit | |
| Update DPD & kolektibilitas | lending | Ambang = param |
| Hitung & posting PPAP/CKPN harian *atau* bulanan | lending/ledger | Frekuensi = param |
| Jatuh tempo deposito & ARO | deposit | |
| Deteksi rekening dormant/ tutup otomatis | deposit | |
| Screening ulang batch (list update) & rule AML harian | compliance | |
| Rekonsiliasi subledger↔GL, TB check | ledger | Gate pasca |
| Snapshot saldo & TB harian | ledger | |
| Rollover business date | platform | |

**EOM (tambahan)**
| Task | Catatan |
|---|---|
| Kapitalisasi/pembayaran bunga simpanan & deposito | Pajak dipotong (tax) |
| Distribusi bagi hasil (nisbah) syariah | Berdasarkan pendapatan riil/ metode param |
| Biaya administrasi bulanan | |
| Pengakuan/ reversal akrual tertentu, amortisasi (provisi/biaya transaksi bila relevan) | |
| Tutup periode GL, laporan keuangan bulanan | `PeriodClosed(month)` |
| Generate laporan regulator bulanan (draft) | Reporting |
| Perhitungan rasio (KPMM, NPL, LDR, BOPO, dll.) | Disimpan sebagai snapshot |
| Re-KYC jatuh tempo, ringkasan APU-PPT | |

**EOQ / EOY (tambahan)**
| Task | Catatan |
|---|---|
| Penilaian kesehatan (triwulan/tahunan sesuai param) | Koperasi/BPR |
| Jurnal penutup tahun (laba/rugi → laba ditahan/ SHU belum dibagi) | |
| **Usulan SHU** (jasa simpanan vs jasa usaha, cadangan, dana-dana) | `coop`, parameter persentase RAT |
| Laporan tahunan & paket RAT | |
| Pembekuan tahun fiskal, arsip partisi, retensi | |
| Bukti potong tahunan & laporan pajak | |

### 11.7 Fitur Operasional
- **Dry-run / Simulation**: jalankan di transaksi yang di-*rollback* (atau di salinan skema) untuk pratinjau dampak (jurnal, saldo) tanpa commit.
- **Resume & Retry**: dari chunk gagal, tanpa mengulang yang sukses.
- **Pause/Cancel** terkontrol (hanya di batas chunk).
- **Skip by rule**: task tidak relevan untuk segmen/hari tertentu (mis. task syariah di koperasi konvensional) — dinyatakan oleh param/pack, tercatat sebagai `SKIPPED` dengan alasan.
- **Back-to-back catch-up**: bila beberapa hari terlewat, orchestrator menjalankan hari demi hari berurutan.
- **Reopen/ Reverse EOD**: **default dilarang**. Jika kebijakan param mengizinkan: hanya periode terbuka, approval berjenjang, otomatis membuat jurnal pembalik, tercatat audit. Koreksi normal = transaksi koreksi di hari berjalan.
- **Backdated transaction**: kebijakan param (maks mundur N hari, hanya role tertentu, selalu maker-checker).
- **Lock**: `pg_advisory_lock` per scope agar tak ada dua run bersamaan.
- **UI Monitor**: DAG, progress per task/chunk, durasi, error, tombol resume; **a11y live region** untuk progres.
- **Notifikasi**: selesai/gagal ke operator.
- **Deploy freeze**: `deploy-vps.sh` menolak deploy saat ada run `RUNNING/CLOSING` (§21.4).

### 11.8 Skema Data Day-Close (ringkas)
```sql
CREATE TABLE daycloser.batch_run (
  run_id uuid PRIMARY KEY, scope_type text, scope_id uuid, business_date date,
  levels text[] NOT NULL, mode text NOT NULL,          -- REAL | SIMULATION
  state text NOT NULL, param_snapshot_id uuid NOT NULL,
  started_at timestamptz, finished_at timestamptz,
  started_by uuid, summary_hash text
);
CREATE TABLE daycloser.batch_task (
  run_id uuid, task_id text, state text, attempt int, started_at timestamptz, finished_at timestamptz,
  error jsonb, metrics jsonb, PRIMARY KEY (run_id, task_id)
);
CREATE TABLE daycloser.batch_task_chunk (
  run_id uuid, task_id text, chunk_no int, range jsonb, state text, attempt int, error jsonb,
  PRIMARY KEY (run_id, task_id, chunk_no)
);
```

---

## 12. Backend Spec (Nim)

### 12.1 Pilihan Teknologi & Risiko
| Kebutuhan | Rekomendasi awal | Catatan |
|---|---|---|
| Versi | **Nim 2.x** (ARC/ORC), `--mm:orc`, `--threads:on` | Jalankan CI dengan sanitizer/valgrind pada test kritis |
| HTTP server | **Mummy** (multithreaded, sederhana) *atau* Prologue | **Dibungkus di `shared/platform-lib/http`** supaya bisa diganti (ADR-002) |
| PG driver | `db_connector` (db_postgres) + pool sendiri, atau driver async pilihan | Wajib parameterized query; pool & timeout dibungkus |
| JSON | `jsony` (cepat) / std `json` | Contract tests menjamin kesesuaian dengan OpenAPI |
| Migrasi | **SQL file + runner** (`tools/dbtools`) | Tanpa ketergantungan ORM |
| Logging | Struktur JSON, correlation ID | Tanpa PII (§18) |
| Test | `unittest2`/std `unittest`, property-based (mis. `testament` + generator sendiri) | |
| Format uang | Tipe `Money` fixed-point sendiri di `shared/kernel` | Uji properti: asosiatif, pembulatan, no overflow |

> **Risiko ekosistem**: library Nim lebih kecil/lebih sedikit maintainer daripada ekosistem mainstream. Mitigasi: batasi dependensi, vendor-kan yang kritis (pin versi + checksum), bungkus di port, tulis ADR per dependensi.

### 12.2 Struktur Modul & Konvensi
- Satu file = satu tanggung jawab; maksimal ~300 baris sebagai panduan.
- `domain/` **tidak boleh** `import` dari `application/`, `infrastructure/`, `interface/`, DB, HTTP.
- Use case = satu objek/ proc dengan input & output eksplisit:

```nim
# modules/deposit/application/open_account.nim
type
  OpenAccountCmd* = object
    partyId*: PartyId
    productId*: ProductId
    initialDeposit*: Money
    ctx*: AuditContext

proc openAccount*(deps: Deps, cmd: OpenAccountCmd): Future[Result[AccountOpened, AppError]] {.async.} =
  # 1. validasi via domain + parameter
  # 2. transaksi: simpan aggregate + tulis outbox (atomik)
  # 3. kembalikan hasil
```
- **Error**: `Result[T, E]` dengan error terkode (`AppError{code, i18nKey, details}`); exception hanya untuk bug/ kondisi tak terduga, ditangkap di batas interface.
- **Transaksi**: unit-of-work di application layer; satu use case = satu transaksi DB (kecuali day-close chunk).
- **Concurrency**: optimistic lock (`version` kolom) pada aggregate; `SELECT … FOR UPDATE` pada saldo rekening untuk posting (urutan lock konsisten untuk hindari deadlock).
- **Idempotency**: header `Idempotency-Key` untuk POST finansial, disimpan di tabel + unique.

### 12.3 Port & Adapter (contoh)
```nim
type
  AccountRepo* = concept r
    r.findById(AccountId) is Future[Option[Account]]
    r.save(Account) is Future[void]
  EventBus* = concept b
    b.publish(DomainEvent) is Future[void]   # implementasi: tulis ke outbox dalam transaksi aktif
  Clock* = concept c
    c.now() is DateTime
    c.businessDate(Scope) is BusinessDate
```
Implementasi Postgres di `infrastructure/`; fake in-memory untuk unit test.

### 12.4 Outbox & Event
- Tulis `platform.outbox` dalam transaksi yang sama dengan perubahan state.
- Dispatcher (worker) membaca batch dengan `SKIP LOCKED`, mengirim ke subscriber in-proc & NOTIFY ke SSE; `inbox` per konsumen untuk de-dup (at-least-once → effectively-once).
- Event punya **versi skema** (`type`, `v`), didokumentasikan di `packages/contracts/events`.

### 12.5 Konfigurasi
- **Bootstrap config** (env var/file): hanya koneksi DB, port, secret key ref, mode role — **bukan** nilai bisnis (itu di DB).
- Secret via mekanisme server existing (§21), tidak di repo.

---

## 13. API Design

- **REST/JSON**, kontrak **OpenAPI 3.1** di `packages/contracts/openapi/` = *sumber kebenaran*. Client TS di-generate (`openapi-typescript` + fetch wrapper tipis).
- **Sisi Nim**: handler ditulis manual mengikuti kontrak; **contract test** (mis. schemathesis/ Dredd-like) di CI memastikan implementasi ≡ OpenAPI.
- **Versi**: `/api/v1/...`; perubahan breaking → v2; deprecation header.
- **Konvensi**: resource-oriented; `PATCH` parsial; paginasi cursor; filter/sort terstandar; waktu ISO-8601; tanggal bisnis `YYYY-MM-DD`; uang sebagai **string desimal** (`"1500000.00"`) + `currency`.
- **Error**: `application/problem+json` (RFC 9457) dengan `code`, `i18nKey`, `params`, `traceId`. Frontend yang menerjemahkan pesan sesuai locale.
- **Idempotency-Key** untuk transaksi; **ETag/If-Match** untuk update (optimistic lock).
- **Realtime**: `GET /api/v1/events/stream` (WebSocket; lihat §19.1) dengan topik berotorisasi (mis. `daycloser.run.{id}`, `account.{id}.balance`).
- **AuthN**: sesi dengan cookie `HttpOnly`+`Secure`+`SameSite=Strict` (BFF-friendly) atau token pendek + refresh; MFA TOTP; parameter kebijakan di DB.
- **AuthZ**: RBAC (permission granular `modul.resource.action`) + *branch scoping* + atribut (limit nominal) + **maker-checker** sebagai kemampuan platform (`/approvals`).
- **Rate limiting** & lockout (param).
- **Audit context** (siapa, cabang, IP, device, alasan) otomatis diteruskan ke use case.

---

## 14. Frontend Spec (SvelteKit + TS)

### 14.1 Teknologi
| Kebutuhan | Pilihan | Alasan |
|---|---|---|
| Framework | **SvelteKit** + **Svelte 5 (runes)**, TS `strict` | Reaktif native, ringan |
| Mode render | **SPA** (`adapter-static`, fallback) untuk back-office; SSR hanya bila perlu | KISS & deploy mudah di server sendiri |
| Server state | **TanStack Query (Svelte)** + invalidasi oleh event realtime | Cache, retry, dedup |
| Form | **Superforms/Formsnap** atau util sendiri + validasi dari skema kontrak | Aksesibel, error terasosiasi |
| Komponen headless a11y | **bits-ui** / Melt UI sebagai dasar, dibungkus di `packages/ui` | Keyboard & ARIA matang |
| Styling | **CSS variables (design tokens)** + Tailwind (opsional) atau CSS modules | Theming mudah |
| i18n | **Paraglide JS** (type-safe, tree-shakable) | §16 |
| Tabel data | Komponen sendiri di `ui` (virtualized, a11y) | Data besar |
| Tes | Vitest, Testing Library, Playwright + axe-core | |

### 14.2 Struktur `apps/web`
```
src/
  routes/                       # SvelteKit routes (tipis; hanya komposisi)
  lib/
    app/                        # shell, layout, nav, guard, error boundary
    features/
      deposit/                  # satu folder fitur per modul backend
        components/  api/  state/  i18n/  routes-meta.ts
      lending/ party/ teller/ ledger/ daycloser/ compliance/ reporting/ coop/ sharia/ platform-admin/
    shared/                     # util non-domain
  app.html  hooks.client.ts
packages/ui                     # komponen presentasional (tanpa logic domain)
packages/api-client             # generated
```
- **Aturan**: `features/*` boleh pakai `packages/ui` & `api-client`; **tidak boleh** saling import antar-fitur (komunikasi via store/ event / URL). Dicek eslint boundaries.
- **Mirror backend**: satu fitur frontend ↔ satu modul backend → mudah dipelajari.

### 14.3 UX Back-Office
- **Keyboard-first**: shortcut teller (F-keys terkonfigurasi), command palette (Ctrl/⌘+K), fokus otomatis logis.
- **Form panjang** (onboarding, pembiayaan): wizard dengan simpan draf otomatis.
- **Tabel**: sort/filter/pin kolom, ekspor, virtualisasi, seleksi massal.
- **Cetak**: buku tabungan (passbook/dot-matrix profile), slip, kuitansi, surat → *print templates* terparameter.
- **Mode layar**: responsif untuk tablet (AO lapangan); desktop-first.
- **Indikator business date & mode** (CLOSING/ simulasi) selalu tampak.

---

## 15. Theming (Dark/Light)

1. **Design tokens** semantik (bukan warna mentah) di `packages/ui/tokens`: `--color-bg`, `--color-surface`, `--color-text`, `--color-text-muted`, `--color-border`, `--color-primary`, `--color-danger`, `--color-success`, `--color-warning`, `--color-focus-ring`, dll. + token spasi, radius, tipografi, elevasi, motion.
2. **Tiga mode**: `light`, `dark`, `system` (default `system`). Pilihan disimpan per pengguna (profil di DB; fallback `localStorage`).
3. Implementasi: atribut `data-theme="light|dark"` di `<html>` + `color-scheme` CSS; token didefinisikan ulang per tema. **Skrip inline kecil di `app.html`** menetapkan tema sebelum render (cegah flash).
4. **Kontras**: seluruh pasangan token diuji otomatis (skrip hitung rasio) — teks normal ≥ **4.5:1**, teks besar & UI ≥ **3:1** pada **kedua** tema (WCAG 2.2 AA). Status tidak hanya dengan warna (ikon + teks).
5. Mendukung `prefers-contrast: more` & `forced-colors` (Windows High Contrast).
6. Cetak selalu mode terang (CSS `@media print`).
7. Grafik/ visualisasi memakai palet aman buta warna + pola/label.
8. **Visual regression test** (Playwright screenshot) untuk komponen kunci di kedua tema.

---

## 16. Internationalization (i18n)

### 16.1 Cakupan & Locale
- Locale awal: **`id-ID` (default)**, **`en`**. Arsitektur siap menambah (mis. `ar` untuk istilah syariah, bahasa daerah) tanpa ubah kode.
- **Backend tidak mengirim kalimat jadi** untuk UI; mengirim **kode + parameter** (`i18nKey`, `params`). Pengecualian: dokumen/ cetakan server-side memakai catalog yang sama.

### 16.2 Mekanisme
| Hal | Pendekatan |
|---|---|
| Katalog pesan | `packages/i18n/messages/{id,en}/<namespace>.json`, namespace = modul. Key hierarkis: `deposit.account.open.title` |
| Library | Paraglide JS (kunci bertipe, tree-shaking) — ADR-009 |
| ICU MessageFormat | Plural, select, gender (mis. "1 rekening" / "{n} rekening") |
| Format angka/tanggal/uang | `Intl.NumberFormat/DateTimeFormat` dengan `id-ID`; mata uang IDR tanpa desimal di tampilan umum, presisi penuh di detail/ laporan |
| Tanggal Hijriah | Opsi tampilan tambahan untuk segmen syariah (`Intl` calendar `islamic`), tidak mengganti business date Masehi |
| Zona waktu | Disimpan UTC; tampil WIB/WITA/WIT sesuai cabang (param) |
| Arah teks | CSS **logical properties** (`margin-inline`, dst.) agar siap RTL |
| Terminologi | **Glosarium** resmi (`docs/glossary.md`): anggota vs nasabah, SHU, PPAP, DPD, dst. — konsisten antar bahasa |
| Konten terparameter | Template notifikasi & cetakan di DB berkunci i18n + variabel |

### 16.3 Tata Kelola & Tooling
- **Larangan string hardcode** di komponen (eslint rule + CI).
- CI memeriksa: key yang dipakai ada di semua locale; tidak ada key yatim; placeholder konsisten.
- **Pseudo-locale** (`xx-pseudo`) untuk menemukan teks terpotong/ hardcode; uji ekspansi teks 30–40%.
- Workflow terjemahan: file JSON di repo (reviewable via PR); opsional integrasi platform terjemahan kemudian.

---

## 17. Accessibility (a11y)

**Target**: **WCAG 2.2 level AA** untuk seluruh UI; panduan tambahan **ARIA Authoring Practices**. (Selaraskan dengan standar nasional bila ada persyaratan klien.)

### 17.1 Fondasi di Design System
- Semua komponen interaktif berbasis elemen semantik (`button`, `a`, `input`, `table`, `dialog`) sebelum ARIA.
- Dialog/ menu/ combobox/ tabs/ tooltip memakai primitif headless teruji (focus trap, `aria-*`, roving tabindex).
- **Focus**: indikator fokus selalu terlihat (kontras ≥ 3:1, WCAG 2.4.11/13), urutan logis, fokus dikembalikan setelah dialog/ navigasi.
- **Target ukuran** minimal 24×24 CSS px (WCAG 2.5.8).
- **Skip links**, landmark (`header/nav/main/aside/footer`), heading hierarchy, judul halaman unik per route (diumumkan saat navigasi SPA).
- **Form**: label terasosiasi, hint & error via `aria-describedby`, ringkasan error dengan fokus, validasi tidak hanya warna, `autocomplete` benar, hindari timeout tanpa peringatan (sesi: peringatan sebelum habis + perpanjang).
- **Tabel data**: `<th scope>`, caption, sortable dengan `aria-sort`, paginasi/ virtualisasi tetap bisa dinavigasi keyboard & diumumkan.
- **Status dinamis** (hasil transaksi, progres EOD, toast): **live region** (`aria-live` polite/assertive sesuai urgensi).
- **Gerak**: hormati `prefers-reduced-motion`; tanpa konten berkedip.
- **Zoom/ reflow**: usable pada zoom 200–400% tanpa scroll dua arah untuk konten utama.
- **Bahasa**: `lang` pada `<html>` dan fragmen bahasa lain (mis. istilah Arab) dengan `lang` sendiri.
- **Cetak & dokumen**: PDF yang dihasilkan sistem (laporan) ditargetkan *tagged* bila memungkinkan (open decision).

### 17.2 Proses & Penegakan
| Tahap | Praktik |
|---|---|
| Dev | `eslint-plugin-svelte` a11y rules `error`; storybook/ katalog komponen dengan addon a11y |
| CI | **axe-core via Playwright** pada rute utama × 2 tema × 2 locale; gagal untuk *serious/critical* |
| Test | Skenario **keyboard-only** (Playwright) untuk alur kritis: login, buka rekening, setoran, pencairan, monitor EOD |
| Manual | Uji rutin dengan **NVDA + Firefox/Chrome**, **VoiceOver**; checklist per rilis |
| Governance | **Definition of Done** fitur UI mencakup a11y checklist; "Accessibility Statement" di dokumentasi |

---

## 18. Security & Data Protection

### 18.1 Prinsip
Defense-in-depth, *least privilege*, *secure by default*, *auditable*.

### 18.2 Kontrol Utama
| Area | Kontrol |
|---|---|
| **Identitas & akses** | MFA (TOTP/ WebAuthn opsional), kebijakan password terparameter, lockout, sesi pendek, deteksi sesi ganda, review akses berkala |
| **Otorisasi** | RBAC granular + *role conflict matrix* (SoD) + branch scoping + limit nominal + maker-checker |
| **Data at-rest** | Disk/ volume terenkripsi + **field-level encryption** untuk data sensitif (NIK, NPWP, no. HP, alamat) memakai envelope encryption (KEK dari server/KMS, DEK per tabel/ record), blind index untuk pencarian |
| **Data in-transit** | TLS 1.2+ (ideal 1.3), HSTS; mTLS untuk adapter kritis |
| **Masking** | Default masked di UI/ log/ ekspor; *unmask* butuh permission + alasan + audit |
| **Audit trail** | Append-only, **hash-chain** (setiap entri memuat hash entri sebelumnya) + anchor harian (hash dicatat di tempat terpisah) |
| **Logging** | Tanpa PII/ secret; correlation ID; retensi sesuai param |
| **Input** | Parameterized SQL, validasi skema, ukuran upload, antivirus scan pada dokumen |
| **Web** | CSP ketat, anti-CSRF, SameSite, header keamanan, sanitasi output (Svelte auto-escape; larang `{@html}` tanpa review) |
| **Supply chain** | Lockfile, pin versi, SBOM (CycloneDX), scan dependensi (OSV), *reproducible build* dilacak |
| **Secrets** | Tidak di repo; di-inject runtime (§21) |
| **Backup & DR** | Backup terenkripsi, uji restore terjadwal, RPO/RTO sebagai target terdokumentasi (nilai ditetapkan institusi) |
| **Retensi & hapus** | Kebijakan retensi (param) + anonimisasi; hak subjek data (akses/koreksi/hapus dengan batasan hukum retensi keuangan) |
| **Insiden** | Runbook insiden + SLA notifikasi pelanggaran data sesuai UU PDP |
| **Pen-test** | Sebelum go-live tiap rilis mayor; temuan ditracking |

### 18.3 RLS (opsional tapi disarankan)
Row-Level Security Postgres untuk branch scoping pada tabel transaksi: aplikasi men-set `SET LOCAL app.user_id/branch_ids` per transaksi; kebijakan RLS menyaring. Trade-off performa diukur (ADR-007).

---

## 19. Reactive Architecture

### 19.1 Backend
```
Use case ─(1 transaksi)─► state change + outbox row
                                  │
                      Dispatcher (SKIP LOCKED)
                       ├─► subscriber in-proc (ledger posting, compliance, notifikasi, read-model updater)
                       └─► NOTIFY ► realtime hub ► klien
```
- **Read model/ projection** untuk layar berat (dashboard, saldo ringkas) diperbarui oleh event handler; boleh direbuild dari ledger.
- **Backpressure**: dispatcher batch + limit konkurensi; *dead-letter* tabel untuk event gagal (dengan UI re-drive).
- **Transport realtime: WebSocket, bukan SSE** (perubahan 2026-10-14, keputusan pemilik atas E-001/ADR-002).
  Alasan: Mummy (server HTTP terpilih) tidak punya API streaming sehingga SSE tidak dapat
  diimplementasikan tanpa menulis soket mentah; Mummy mendukung WebSocket first-class. Endpoint
  tetap `GET /api/v1/events/stream` (upgrade ke WS) dengan *resume token* sebagai pengganti
  `Last-Event-ID`. Kontrak pesan memakai amplop yang sama (`id`, `topic`, `payload`).

### 19.2 Frontend
- `$state/$derived/$effect` untuk state lokal; **query cache** untuk server state.
- Event realtime (WS) → handler mengubah/ meng-*invalidate* query terkait (mis. `account.{id}.balance` → refetch/ patch saldo).
- Optimistic update hanya untuk operasi non-finansial; operasi finansial menunggu konfirmasi server (korektness > kecepatan).
- Aksesibilitas reaktif: pembaruan real-time diumumkan via live region secukupnya (hindari kebisingan).
- Reconnect WS membawa *resume token* (id event terakhir) agar tak kehilangan event; server memutar ulang dari outbox.

---

## 20. Testing Strategy

| Level | Cakupan | Alat |
|---|---|---|
| **Unit (domain)** | Aturan bisnis, `Money`, perhitungan bunga/ angsuran/ kolektibilitas | Test Nim + **property-based** (invarian: debit=kredit, saldo≥0, pembulatan) |
| **Golden/ Reference** | Perhitungan akrual, jadwal angsuran (flat/efektif/anuitas, syariah), PPAP, SHU — dibandingkan dengan **kasus referensi tervalidasi** (spreadsheet akunting) | File fixture ter-versi |
| **Integration** | Use case + Postgres nyata (container) + migrasi | Test runner + DB ephemeral |
| **Contract** | OpenAPI ↔ implementasi; event schema | schemathesis/ validator JSON Schema |
| **Day-close simulation** | *Time-travel* dengan `Clock` injeksi: simulasi N bulan/ 1 tahun penuh (termasuk libur, EOM, EOY, catch-up, kegagalan chunk) | Harness sintetik |
| **Param-driven** | Mutasi parameter → perilaku berubah (anti-hardcode) | Test generik per key |
| **Performance** | EOD pada volume target; query kritis | Dataset sintetis; budget waktu di CI nightly |
| **Security** | SAST, dependency scan, authz test matrix, fuzz input | |
| **Frontend** | Unit (Vitest), komponen, e2e (Playwright), **a11y (axe)**, visual regression 2 tema, i18n (pseudo-locale) | |
| **Compliance trace** | Setiap `requirement` aktif ↔ ≥1 test tag `@REG-xxx`; gate CI | |
| **Migration** | Up pada snapshot data realistis; verifikasi ukuran/ waktu | |
| **UAT** | Skenario bisnis per segmen bersama pengguna nyata | Checklist & sign-off |

**Definition of Done (fitur)**: kode + test + OpenAPI + i18n (id & en) + a11y check + parameter/seed + MODULE.md + audit event + (bila relevan) requirement regulasi ter-link.

---

## 21. CI/CD (Ikuti Pola Existing)

> **Prinsip**: KRAN mengikuti pola yang *benar-benar berjalan* di server (hasil audit setup: GitHub Actions = gerbang verifikasi, deploy = webhook → `deploy-vps.sh` di VPS, build di VPS, Caddy, systemd user unit/ quadlet, env file mode 600). Tidak ada tool baru yang diperkenalkan. Yang ditambahkan hanyalah **kontrol khusus KRAN** (deploy-freeze day-close, migrasi aman, backup pra-migrasi, rollback otomatis). Item bertanda *(inferensi)* berasal dari analisis audit, bukan prosedur terdokumentasi.

### 21.1 Ringkasan Pola Existing

| Aspek | Pola existing |
|---|---|
| **CI** | GitHub Actions, satu `ci.yml` per repo; trigger `push: [main]` + `pull_request`; `permissions: contents: read`; `concurrency` cancel-in-progress. **Verifikasi saja** — tidak push image/ artifact, tidak memanggil webhook. |
| **Cetakan terbaik** | **Skyward**: job `db-tests` (`services: postgres:18` + migrasi, serial), gitleaks, binary native diekstrak dari image → `bin/<app>` (systemd user unit), health gate `/readyz` poll 15× + **auto-rollback**, gate migrasi, `.deployed_rev`, skrip self-update. |
| **Deploy** | GitHub webhook → `webhook.service` (adnanh/webhook, `127.0.0.1:9000`, diekspos Caddy `/hooks/*`) → `/srv/qouver/apps/<app>/scripts/deploy-vps.sh`. |
| **Kontrak skrip** | `set -euo pipefail` → ref-guard fail-closed (hanya `refs/heads/main`) → `git fetch && reset --hard origin/main` → rebuild selektif (diff `apps/api/` vs `apps/web/`) → `podman build` → `systemctl --user daemon-reload` + restart → `is-active` → log `deploy.log`. |
| **Artefak** | Image `localhost/<app>:local` (satu tag, ditimpa) **atau** binary native (Skyward); web = folder statis swap `web.new → web`, `web.prev` disimpan. Semua dibangun **di VPS**. |
| **Proxy/TLS** | Caddy (ACME otomatis), upstream `127.0.0.1`, hanya 22/80/443 publik. Caddyfile *hand-maintained* (belum di version control). |
| **Secret** | Tanpa secret manager. Runtime: `EnvironmentFile=` → `/srv/qouver/apps/<app>/env/<app>-prod.env` (600). Repo hanya `*.example`. Fetch repo privat via **deploy key SSH per repo**. HMAC webhook di `/srv/qouver/config/webhook.json` (600). |
| **Rollback** | Hanya Skyward yang otomatis. Lainnya: revert commit lalu push *(inferensi)*. Image `:local` satu tag ⇒ tidak bisa retag. |
| **DB** | Backup Postgres 02:00 (retensi daily 7 / weekly 28 / monthly 84). **Restore test belum pernah dilakukan.** `scripts/migrate.sh --down` manual & opt-in. |

### 21.2 Keputusan: KRAN = Turunan Pola Skyward

**Alasan**: (1) paling matang & sudah terbukti di server; (2) Nim menghasilkan **binary native** → cocok dengan model Skyward (ekstrak binary dari image, jalan sebagai systemd user unit, tanpa runtime container); (3) konsisten dengan `audit-consistency.sh` yang membandingkan md5 skrip repo vs server.

```
git push main ──► GitHub Actions (ci.yml: verifikasi saja)           [gerbang kualitas, tanpa deploy]
        │
        └──────► GitHub webhook (HMAC sha256) ──► Caddy /hooks/* ──► webhook.service
                                                                         │
                                                  /srv/qouver/apps/kran/scripts/deploy-vps.sh  (di VPS)
                          ref-guard → lock → fetch/reset → FREEZE GATE → pre-migration dump
                          → build (podman) → ekstrak bin/kran-api → MIGRATION GATE (expand-only)
                          → swap web → restart units → HEALTH GATE (/readyz ×15) → [auto-rollback] → .deployed_rev
```

### 21.3 `ci.yml` untuk KRAN (verifikasi saja)

Trigger/ permission/ concurrency **identik** dengan repo lain. Job (paralel bila bisa):

| Job | Isi |
|---|---|
| `nim-check` | Pin versi Nim; format check, kompilasi `--mm:orc`, `archcheck`, `lint-nomagic`, `paramgen --check` (kode ≡ definisi), unit + property test |
| `db-tests` | Cetak Skyward: `services: postgres:18`, jalankan migrasi (up), integration test **serial**, test day-close simulation, param-driven test |
| `contract` | Lint OpenAPI, contract test implementasi ↔ OpenAPI, validasi event schema |
| `web` | pnpm install (lockfile frozen), eslint (termasuk a11y rules & no-hardcoded-string), svelte-check/ typecheck, vitest, build, i18n check (key lengkap `id`/`en`, tanpa key yatim) |
| `e2e-a11y` | Playwright: alur kritis keyboard-only + **axe-core** (rute utama × tema light/dark × locale id/en) + visual regression; gagal bila axe *serious/critical* |
| `security` | **gitleaks**, dependency scan (OSV), SAST |
| `traceability` | Setiap requirement regulasi aktif punya kontrol + test (§4.4) |

Secret CI tetap minim: `GITHUB_TOKEN` dan `KRAN_TEST_DATABASE_URL`. **Tidak ada** secret SSH/ deploy di CI.

### 21.4 Webhook & `deploy-vps.sh`

**Hook baru `kran`** di `webhook.json`: `execute-command: /srv/qouver/apps/kran/scripts/deploy-vps.sh`, argumen `repository.name` + `ref`. **Gunakan `payload-hmac-sha256` + `X-Hub-Signature-256`** (4 hook lama masih sha1 — jangan diwariskan).

Langkah skrip (ekstensi kontrak seragam; yang **tebal** = tambahan KRAN):

| # | Langkah | Catatan |
|---|---|---|
| 1 | `set -euo pipefail`; ref-guard hanya `refs/heads/main` (fail-closed) | Seragam |
| 2 | **Lock** (`flock`) agar dua deploy tak berjalan bersamaan | Tambahan |
| 3 | `git fetch origin main && git reset --hard origin/main` | Seragam |
| 4 | **FREEZE GATE**: cek state `daycloser` (read-only: `kran-api --role=ctl daycloser-status` atau query). Bila `CLOSING/RUNNING` → exit tanpa mengubah apa pun, tulis log, jadwalkan retry | Tambahan (§11.7) |
| 5 | Rebuild selektif berdasar diff (`apps/api`, `modules/`, `shared/`, `apps/web`, `migrations/`) | Seragam |
| 6 | **Pre-migration dump** bila ada migrasi baru: `pg_dump -Fc` → `/srv/qouver/backups/pre-deploy/<sha>.dump`, verifikasi `pg_restore --list` | Tambahan |
| 7 | Build image `podman build`; **tag `:<sha>` + `:local`; simpan tag sebelumnya sebagai `:prev`**; ekstrak binary → `bin/kran-api` (lama → `bin/kran-api.prev`) — **hanya untuk gate host**, layanan berjalan dari image (D-066) | Pola Skyward; menutup celah "satu tag" |
| 8 | **MIGRATION GATE**: `kran-api --role=migrate --check` lalu `--up` (**expand-only**). Gagal ⇒ **deploy dibatalkan sebelum binary diganti** | Pola Skyward |
| 9 | Web: build ke `web.new` → swap → `web.prev` disimpan | Seragam (pola Skyward/Fond) |
| 10 | `systemctl --user daemon-reload` + restart `kran-api` & `kran-worker` | Seragam |
| 11 | **HEALTH GATE**: poll `/readyz` ×15 (cek DB, versi migrasi, **startup param check**, drift paramgen). Gagal ⇒ **auto-rollback** (tag image `:prev` → `:local`, unit `.prev`, `bin/kran-api.prev`, `web.prev`), exit 1 | Pola Skyward; **bukan** `is-active` + curl yang diabaikan |
| 12 | Tulis `.deployed_rev`; log ke `deploy.log` **dan** journal; skrip self-update via `mv` | Pola Skyward |
| 13 | **Evidence rilis**: simpan SBOM, daftar migrasi, ringkasan test (dari CI), hash binary di `/srv/qouver/apps/kran/releases/<sha>/` | Tambahan (jejak audit; log GitHub Actions hanya ±90 hari) |

> **Amandemen 19 Okt 2026 (D-066):** layanan `--role=api` dan `--role=worker` berjalan sebagai
> **container quadlet** (`ops/systemd/kran-{api,worker}.container`, image `localhost/kran-api`),
> dipasang dan di-rollback oleh `deploy-vps.sh`. `bin/kran-api` dipertahankan hanya karena FREEZE
> dan MIGRATION gate berjalan di host. §21.5 diperbarui; §21.6 menampilkan struktur `ops/` terbaru.

**Aturan migrasi**: hanya **expand** (additive, kompatibel dengan binary lama) yang otomatis. Migrasi **contract** (drop/rename/ketat) ada di `migrations/contract/` dan hanya dijalankan manual via `scripts/migrate.sh --contract --yes` *setelah* rilis berikutnya stabil. Konsekuensi: auto-rollback binary selalu aman terhadap skema. Tidak ada `--down` otomatis; koreksi = migrasi maju, atau restore dari dump pra-migrasi bila terpaksa.

### 21.5 Komponen Runtime KRAN di VPS

| Komponen | Spesifikasi |
|---|---|
| Direktori | `/srv/qouver/apps/kran/{scripts,bin,web,env,logs,releases}` |
| Unit | `kran-api.service` (`--role=api`), `kran-worker.service` (`--role=worker`) — systemd **user** unit, binary `bin/kran-api`. **Digantikan D-066 (19 Okt 2026):** container quadlet `kran-api.container`/`kran-worker.container`, image `localhost/kran-api`; biner host hanya untuk gate deploy |
| Env | `env/kran-prod.env` (mode 600, owner sachiel) berisi **bootstrap config saja** (DB URL, port, role, referensi kunci) — nilai bisnis tetap di DB (§10) |
| Port | `127.0.0.1:<port-baru>` selama transisi; 8095 baru dilepas/ diambil alih saat cutover (§21.9) |
| Caddy | Site/hostname **terpisah** untuk KRAN dengan header keamanan lengkap (CSP, HSTS, X-Content-Type-Options, frame-ancestors, Referrer-Policy). Jangan menumpang `api.qouver.com` yang saat ini tanpa header keamanan |
| Git | Deploy key SSH per repo (alias `~/.ssh/config`, mis. `github-kran:...`) |
| Webhook | Hook `kran` (sha256), secret di `webhook.json` (600) |
| Database | Database & role Postgres khusus KRAN; role terpisah untuk `app`, `migrate`, `readonly/report` (least privilege) |

> **Catatan nama**: KRAN **menggantikan** `cbs-core` (nama transisi `cbs` dibatalkan oleh D-039: produk
> dan seluruh identifier teknis memakai KRAN). Hook/ image/ unit/ port/ hostname/ direktori milik
> `cbs-core` yang masih melayani — `cbs-core`, image `localhost/kran-*:local`, route `/cbs/*→8095`,
> site `cbs`→3005 — **tidak boleh bertabrakan** dengan yang baru (bila `/srv/qouver/apps/kran/` sudah
> dipakai `cbs-core`, pakai `apps/kran-next/` sementara lalu rename saat cutover). Pengambilalihan nama
> dilakukan di cutover (§21.9).

### 21.6 Struktur `ops/` di Repo

```
ops/
├─ scripts/
│  ├─ deploy-vps.sh          # kontrak §21.4 (md5 repo == server; masuk audit-consistency.sh)
│  ├─ migrate.sh             # --up | --check | --contract --yes | --down --yes [N] (manual, opt-in)
│  ├─ backup-pre-deploy.sh
│  ├─ rollback.sh            # manual: image :prev -> :local, web.prev, unit .prev (tanpa DB)
│  └─ smoke.sh               # /healthz, /readyz, versi == .deployed_rev
├─ systemd/                  # kran-api.container, kran-worker.container (+ superseded/*.service)
├─ caddy/                    # Caddyfile.kran.example  (+ mulai versi-kan Caddyfile asli)
├─ webhook/                  # hook.kran.json.example (sha256)
└─ env/                      # kran-prod.env.example   (*.env di-gitignore)
```

### 21.7 Penyesuaian terhadap Pola (Deviasi Sadar)

| Kebutuhan KRAN | Pola existing | Keputusan |
|---|---|---|
| Artefak yang diuji = yang di-deploy | Build ulang di VPS setelah CI hijau | Diterima. Kompensasi: toolchain Nim & base image **dipin (digest)**, tag `:<sha>`, `.deployed_rev`, hash binary di `releases/<sha>/`, build reproducible diupayakan |
| Staging dengan data teranonimisasi | Tidak ada (satu stack prod) | **Usulan**: stack staging di VPS yang sama, port/ DB/ hostname berbeda, di-deploy dari branch `staging` (ref-guard diperluas eksplisit: `main`→prod, `staging`→staging). Data prod tidak pernah disalin mentah (`dbtools anonymize`) |
| Artefak kepatuhan per rilis | CI tidak upload artifact | Disimpan di server (`releases/<sha>/`), bukan di Actions |
| Approval manual sebelum prod | Push ke `main` = deploy | Diatur lewat **branch protection** (PR review wajib) + deploy hanya dari `main`. Untuk perubahan kritis tambahkan tag/rilis manual sebagai pemicu (opsional) |
| Deploy-freeze | Tidak ada | Freeze gate di skrip (§21.4 #4) |
| Rollback seragam | Hanya Skyward | KRAN punya sejak hari pertama (§21.4 #7, #11) |

### 21.8 Celah Existing yang Wajib Ditutup *Sebelum Data Nasabah Asli*

| Celah (dari audit) | Dampak ke KRAN | Tindakan |
|---|---|---|
| **Restore test belum pernah dilakukan** | Backup yang belum teruji = belum punya backup | **Gate go-live**: restore test bulanan + dicatat di `docs/runbooks` |
| Backup harian (RPO s.d. 24 jam) | Terlalu longgar untuk uang nyata | Tambahkan **WAL archiving/PITR** untuk DB KRAN (§22) |
| Tanpa secret manager | Kunci enkripsi field (KEK) berisiko | Minimal: KEK di file terpisah (600), **tidak ikut backup DB yang sama**, salinan offline; rencanakan `age`/`sops` kemudian. Dicatat sebagai risiko residual |
| Caddyfile tanpa version control (±4 `.bak`) | Config proxy KRAN tak teraudit | Versi-kan di `ops/caddy/` (dan repo `vps` bila ada) |
| 4 hook masih sha1 | Lemah | Hook KRAN sha256; migrasikan hook lain terpisah |
| Health gate "palsu" di cbs/sds/majadu | Deploy rusak lolos | KRAN memakai gate nyata (§21.4 #11) |
| `deploy.log` kosong (sds) | Jejak deploy hilang | KRAN menulis ke log **dan** journal |
| Key CI di `authorized_keys` memberi shell penuh; HMAC dirotasi manual | Risiko pivot | `restrict,from=` untuk key; jadwalkan rotasi HMAC |
| Semua app berbagi satu VPS | Build Nim & EOD berebut resource dengan app lain; blast radius | Ukur; untuk produksi nyata pertimbangkan VPS/ instance Postgres khusus KRAN |

### 21.9 Cutover & Dekomisioning `cbs-core`

Prinsip: `cbs-core` **tetap melayani sampai `cbs` lulus UAT pilot**; tidak ada big-bang tanpa jalan mundur. `cbs-core` (Go) diperlakukan sebagai **referensi**, bukan basis kode — tidak ada port kode Go → Nim.

| # | Tahap | Isi |
|---|---|---|
| 1 | **Inventaris** (Fase 0) | Catat fitur, skema DB, aturan bisnis yang sudah tervalidasi, data uji, bug/ pelajaran di `docs/migration/cbs-core-inventory.md`. Kasus-kasus validnya dijadikan **golden test** `cbs` (§20) |
| 2 | **Bangun berdampingan** | Nama transisi (§21.5); `cbs-core` tidak disentuh |
| 3 | **Migrasi data** *(hanya bila `cbs-core` berisi data nyata)* | ETL idempotent di `tools/dbtools` → model baru; **rekonsiliasi** sebelum/ sesudah (jumlah rekening, saldo per produk, trial balance); latihan berulang pada salinan (teranonimisasi bila untuk staging); hasil rekonsiliasi disimpan sebagai evidence rilis |
| 4 | **Shadow/ paralel** *(opsional, bila ada data nyata)* | Skenario transaksi yang sama dijalankan di keduanya, hasil dibandingkan |
| 5 | **Cutover** (maintenance window) | Freeze `cbs-core` (read-only) → dump final → ETL final → rekonsiliasi lulus → Caddy `/cbs/*` & site `cbs` diarahkan ke upstream baru → hook `cbs-core` dihapus dari `webhook.json` |
| 6 | **Masa tenggang** | `cbs-core` tetap hidup read-only; rollback cutover = kembalikan Caddy ke upstream lama |
| 7 | **Dekomisioning** | Stop+disable unit, hapus image `localhost/kran-*:local` lama, arsipkan repo `cbs-core`, simpan dump final (retensi sesuai kebijakan data keuangan), cabut deploy key, keluarkan dari `audit-consistency.sh`, perbarui `SERVER_STATE.md`, bersihkan `.bak` Caddy terkait |

Bila `cbs-core` ternyata prototipe tanpa data nyata, tahap 3–4 dilewati (cukup arsip dump).

---

## 22. Observability & Operasional

- **Logging**: JSON terstruktur, level terkonfigurasi, correlation ID lintas request/ event/ batch.
- **Metrics**: Prometheus-style endpoint (latensi, error rate, pool PG, antrian outbox, durasi task day-close, jumlah chunk gagal).
- **Tracing**: OpenTelemetry (opsional fase 2) — minimal propagasi `traceId`.
- **Health**: `/healthz` (liveness), `/readyz` (DB, migrasi, param check).
- **Alert** (contoh): outbox lag > X, day-close terlambat/ gagal, TB tidak seimbang, lonjakan login gagal, restore test gagal.
- **Runbook** (`docs/runbooks`): EOD gagal & resume, TB selisih, restore DB, rotasi kunci, insiden data pribadi, penambahan hari libur darurat.
- **Operasi data**: backup terenkripsi + PITR (WAL archiving), uji restore berkala, retensi & arsip partisi lama.
- **Kapasitas**: tuning PG (pool, autovacuum partisi besar), indeks terpantau; budget performa di CI nightly.

---

## 23. Roadmap & Milestone

> Skala produk ini **sangat besar** untuk satu developer. Strategi: **vertical slice** — selesaikan satu segmen end-to-end dulu (disarankan **Koperasi Simpan Pinjam**: scope terkecil dengan nilai nyata), lalu tambah pack.

| Fase | Fokus | Deliverable utama | Kriteria selesai |
|---|---|---|---|
| **0. Fondasi** | Monorepo, tooling, CI sesuai pola existing, **inventaris `cbs-core`**, `shared/kernel`, `platform` (auth, RBAC, audit, **param framework**, kalender, outbox, i18n, design system dasar + tema), template modul, `archcheck`/`lint-nomagic`/`paramgen` | Skeleton jalan end-to-end (login → ubah param → audit → event realtime WS) | Semua gate CI aktif; hello-module < 1 hari |
| **1. Core Ledger & Party** | `party` (CIF+KYC dasar), `ledger` (COA, posting rule, periode), `product` factory | Jurnal immutable, TB, produk parametrik | Property test double-entry lulus |
| **2. Deposit + Teller** | Rekening simpanan (pokok/wajib/sukarela/tabungan), teller session, cetak | Transaksi tunai & PB, saldo realtime | Alur teller keyboard-only lulus a11y |
| **3. Day-Close Framework** | `daycloser` penuh (EOD/EOM/EOY), task deposit & ledger, simulasi, UI monitor | Simulasi 12 bulan sintetis lulus | EOD target performa tercapai |
| **4. Lending** | Pengajuan→pencairan→angsuran, DPD, kolektibilitas, PPAP, restruk | Siklus pinjaman penuh + task day-close | Golden test vs spreadsheet akunting |
| **5. Koperasi Pack** | `coop` (keanggotaan, SHU, RAT), laporan & rasio kesehatan | **MVP Koperasi siap pilot** | UAT koperasi sign-off |
| **6. Compliance & Reporting** | APU-PPT (screening, rule, case), regulatory register, pelaporan, pajak | Traceability gate aktif | Verifikasi oleh compliance owner |
| **7. BPR Pack** | KPMM, BMPK, tingkat kesehatan, laporan OJK BPR, TI governance docs | Pilot BPR | UAT BPR |
| **8. Syariah Pack (BPRS/BMT)** | `sharia`: akad, nisbah, bagi hasil, DPS, dana kebajikan | Pilot BMT/BPRS | Review DPS |
| **9. Integrasi & Hardening** | Adapter (Dukcapil, SLIK, notif), pen-test, DR drill, perf tuning, **cutover & dekomisioning `cbs-core`** | Rilis 1.0 | Checklist go-live |

Estimasi waktu sengaja tidak dicantumkan sebelum ada keputusan kapasitas tim; tetapkan setelah Fase 0 (ukur *velocity* nyata).

---

## 24. Risiko

| Risiko | Dampak | Mitigasi |
|---|---|---|
| Scope terlalu besar | Tidak selesai | Vertical slice per segmen, pack bertahap, Non-goals tegas |
| Ekosistem Nim kecil | Library hilang/ bug | Bungkus lewat port, minim dependensi, pin & vendor, ADR |
| Salah interpretasi regulasi | Non-compliance | Compliance owner, register ter-versi, verifikasi eksternal, UAT |
| Regulasi berubah | Rework | Parameter/ pack effective-dated; modul rule data-driven |
| Kesalahan perhitungan uang | Kerugian/ temuan audit | `Money` fixed-point, property + golden test, rekonsiliasi harian |
| Day-close gagal di tengah | Operasional terhenti | Idempotent, chunk resume, simulasi, runbook |
| Kebocoran data pribadi | Sanksi UU PDP | Enkripsi field, masking, audit akses, insiden runbook |
| Over-engineering | Lambat | KISS gates; ADR wajib untuk tambah kompleksitas |
| a11y/ i18n jadi beban belakangan | Rework besar | Dimasukkan DoD & CI sejak Fase 0 |
| Single point of expertise | Bus factor | Dokumentasi, template, ADR, runbook |
| Pengetahuan/ aturan valid di `cbs-core` hilang saat rewrite | Regresi | Inventaris Fase 0, golden test dari kasus `cbs-core`, shadow run bila ada data nyata |

---

## 25. ADR Awal

| ID | Keputusan | Alternatif | Status |
|---|---|---|---|
| ADR-001 | **Modular monolith** + schema per modul | Microservices | Diusulkan |
| ADR-002 | HTTP server Nim dibungkus abstraksi; kandidat **Mummy**/Prologue | Jester, custom | Perlu benchmark |
| ADR-003 | **Contract-first OpenAPI**; client TS digenerate | tRPC-style / gRPC | Diusulkan |
| ADR-004 | **Postgres sebagai queue/ event/ scheduler** (outbox, SKIP LOCKED, LISTEN/NOTIFY) | Kafka/Redis/ RabbitMQ | Diusulkan (KISS) |
| ADR-005 | **Single-tenant per deployment** (satu institusi per DB), multi-cabang didukung | Multi-tenant RLS dari awal | Diusulkan — lihat §26 |
| ADR-006 | **Ledger immutable + saldo turunan**, reversal untuk koreksi | Mutable balance | Diusulkan |
| ADR-007 | RLS untuk branch scoping | Filter di aplikasi saja | Perlu ukur performa |
| ADR-008 | **Parameter DB-driven dengan enforcement bertingkat** (compile, lint, startup, governance) | Config file | Diusulkan (inti) |
| ADR-009 | **Paraglide JS** untuk i18n | svelte-i18n, i18next | Diusulkan |
| ADR-010 | Day-close sebagai framework DAG idempotent berbasis checkpoint per entitas | Cron script per modul | Diusulkan (inti) |
| ADR-011 | Uang `NUMERIC(24,4)` + `Money` fixed-point Nim | Float/ Decimal lib | Diusulkan |
| ADR-012 | SPA `adapter-static` untuk back-office | SSR penuh | Diusulkan |
| ADR-013 | Mesin PDF/ cetak (HTML→PDF, Typst, dsb.) | — | **Terbuka** — butuh spike |
| ADR-014 | CI/CD = turunan pola **Skyward** (Actions verifikasi saja → webhook → `deploy-vps.sh`, binary native, health gate + auto-rollback, migrasi expand-only) | Pipeline baru (GHCR/registry, k8s) | Diusulkan (§21) |
| ADR-015 | KRAN **menggantikan** `cbs-core` lewat cutover bertahap (referensi, bukan port kode; `cbs-core` hidup sampai UAT pilot lulus) | Big-bang; evolusi `cbs-core` (Go) | Diputuskan oleh pemilik |
| ADR-016 | (kandidat, belum diangkat) `paramgen` sebagai alat kritis | — | Kandidat (lihat `docs/DECISIONS.md` D-014) |
| ADR-017 | **Enkripsi field-level** (§18.2): envelope KEK→DEK turunan (`HMAC-SHA256`) + AES-256-GCM + blind index; KEK di berkas terpisah mode 600. Detail: `docs/adr/017-field-level-encryption.md` | DEK terbungkus di tabel DB; `pgcrypto`; HKDF penuh; envelope per-record | Diputuskan (desain — `HUMAN-REVIEW-REQUIRED` sebelum data nyata) |

Format ADR: konteks → keputusan → konsekuensi → alternatif → status. Disimpan di `docs/adr/NNN-judul.md`.

---

## 26. Open Questions & Asumsi

### 26.1 Asumsi yang saya pakai (silakan veto)
1. **Single-tenant per deployment**; satu institusi punya banyak cabang. Multi-tenant SaaS = fase lanjut.
2. **Start dari Koperasi** sebagai vertical slice pertama, bukan paralel ketiga segmen.
3. **Back-office web saja** pada v1 (tanpa mobile/ internet banking).
4. **Bahasa UI**: `id` (default) dan `en`.
5. **Backend satu binary** multi-role (api/worker/migrate).
6. **Cetak buku tabungan** dianggap kebutuhan nyata (dot-matrix/ printer buku), detail menyusul.
7. Integrasi eksternal (Dukcapil, SLIK, PPATK goAML, BI-FAST) di fase akhir lewat adapter.
8. KRAN **menggantikan** `cbs-core` (bukan berdampingan permanen): berjalan dengan nama transisi sampai cutover (§21.9), mengikuti pola Skyward; staging di VPS yang sama dari branch `staging` (§21.7).

### 26.2 Pertanyaan terbuka
1. Apakah **`cbs-core` berisi data/ pengguna nyata** yang harus dimigrasikan? Menentukan perlu-tidaknya ETL & shadow run (§21.9 tahap 3–4).
2. Target institusi pertama: apakah ada **calon pengguna/ pilot** (koperasi/ BPR tertentu) yang bisa jadi acuan alur nyata?
3. Apakah ada akses ke **compliance officer/ konsultan** untuk memvalidasi register §4?
4. Volume target (jumlah anggota/ rekening/ transaksi per hari) untuk menetapkan budget performa.
5. Kebutuhan **hosting**: on-premise di institusi vs server pusat Anda (berpengaruh ke data residency, DR, multi-tenant).

---

## 27. Lampiran

### A. Konvensi Penamaan
- Modul: `snake_case` singkat (`deposit`). Schema DB = nama modul.
- Parameter key: `modul.kategori.nama` (huruf kecil, titik).
- Event: `PascalCase` lampau (`LoanDisbursed`), versi `v1`.
- i18n key: `modul.area.elemen.aksi` (mis. `deposit.account.open.submit`).
- Permission: `modul.resource.action` (mis. `deposit.account.create`).
- Kode error: `MODUL-NNNN` (mis. `DEP-1001`).

### B. Template `MODULE.md`
```
# <modul>
## Tujuan & Bounded Context
## Aggregate & Aturan Bisnis Utama
## Public API (api.nim)
## Event dipublish / dikonsumsi (versi)
## Parameter key (+ sensitivitas, regulatory_refs)
## Tabel & schema
## Task day-close yang didaftarkan
## Permission
## Namespace i18n
## Requirement regulasi terkait (REG-xxx → test)
## Keputusan & trade-off (link ADR)
```

### C. Checklist Review PR
- [ ] Batas arsitektur terjaga (archcheck hijau)
- [ ] Tidak ada magic number bisnis; param baru terdaftar + seed + schema
- [ ] Uang hanya lewat `Money`; tidak ada float
- [ ] Use case atomik; event lewat outbox
- [ ] OpenAPI diperbarui; contract test lulus
- [ ] i18n id+en lengkap; tidak ada string hardcode
- [ ] a11y: keyboard, fokus, label, kontras 2 tema, axe hijau
- [ ] Test (unit/ property/ integration) + requirement regulasi ter-tag
- [ ] Audit & permission tepat; data sensitif ter-mask/ terenkripsi
- [ ] Migrasi aman (expand/contract), dokumentasi & MODULE.md diperbarui

### D. Glosarium Singkat
**KRAN** Core Banking System · **CIF** Customer Information File · **KYC/CDD/EDD** Know Your Customer / Customer & Enhanced Due Diligence · **APU-PPT** Anti Pencucian Uang & Pencegahan Pendanaan Terorisme · **DTTOT** Daftar Terduga Teroris dan Organisasi Teroris · **PEP** Politically Exposed Person · **CTR/STR** Cash/ Suspicious Transaction Report · **DPD** Days Past Due · **PPAP/CKPN** Penyisihan Penghapusan Aset Produktif / Cadangan Kerugian Penurunan Nilai · **KPMM** Kewajiban Penyediaan Modal Minimum · **BMPK/BMPP** Batas Maksimum Pemberian Kredit/ Pinjaman · **SHU** Sisa Hasil Usaha · **RAT** Rapat Anggota Tahunan · **KSP/USP/KSPPS/USPPS** Koperasi Simpan Pinjam / Unit Simpan Pinjam / (Pembiayaan) Syariah · **DPS** Dewan Pengawas Syariah · **DSN-MUI** Dewan Syariah Nasional MUI · **EOD/EOM/EOQ/EOY** End of Day/Month/Quarter/Year · **ADR** Architecture Decision Record.

### E. Contoh Posting Rule (data, bukan kode)
```yaml
- event: DepositPosted
  when: { product_type: SAVINGS_COOP_VOLUNTARY }
  entries:
    - { side: DEBIT,  gl: CASH_ON_HAND,           amount: "$amount" }
    - { side: CREDIT, gl: SAVINGS_VOLUNTARY_LIAB, amount: "$amount" }
- event: LoanDisbursed
  when: { product_type: LOAN_COOP_STANDARD }
  entries:
    - { side: DEBIT,  gl: LOAN_RECEIVABLE,        amount: "$principal" }
    - { side: CREDIT, gl: CASH_ON_HAND,           amount: "$net_disbursed" }
    - { side: CREDIT, gl: FEE_INCOME_PROVISION,   amount: "$provision_fee" }
```
(`gl` adalah kode logis → dipetakan ke COA konkret oleh parameter/ pack.)

---
*Akhir dokumen. Versi 0.1 — langkah berikutnya: pastikan status data `cbs-core` (§26.2), validasi §4 oleh compliance owner, lalu finalisasi ADR Fase 0.*
