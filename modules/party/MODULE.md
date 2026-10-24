# Modul `party`

## Tujuan & Bounded Context

`party` memiliki **identitas** pihak (nasabah/anggota/lembaga): nomor CIF, jenis
(`PERSON`/`ORG`), nama tampil, status, cabang pemilik, **dokumen identitas terenkripsi**
(T-071), **detail PII orang/lembaga + alamat terenkripsi** (T-078), serta profil KYC + riwayat
rating risiko. Modul ini **bukan** tempat rekening/transaksi (`ledger`/`account`), bukan tempat
skor risiko otomatis (`compliance`/`lending`). Bounded context lain hanya berbicara lewat
`api.nim` dan event (spec §6.3).

## Aggregate & Aturan Bisnis Utama

- `Party` (`domain/party.nim`): `partyId`, `cif`, `kind`, `displayName`, `status`, `branchId`.
  Validasi: jenis dikenal, nama dinormalisasi (spasi dirapikan) dan 2–200 karakter tanpa karakter
  kontrol, status awal `ACTIVE`.
- CIF (`domain/cif.nim`): pola dari parameter `party.cif.format`; token `{seq:N}` (satu, wajib)
  dan `{check}` (Luhn mod 10, hanya di akhir). Panjang maksimum 32 (batas kolom), karakter aman
  `A-Z a-z 0-9 - _ . /`.
- Nomor urut dari sequence `party.cif_seq`; CIF **boleh berlubang** bila transaksi batal.
- `IdentityDoc` (`domain/identity.nim`): jenis dokumen dari parameter, nomor dinormalkan (huruf
  besar, `A-Z0-9`), panjang tetap per jenis dari parameter. **Modul tidak menyentuh kriptografi**:
  ciphertext + blind index dibuat composition root (ADR-017/D-048/D-069).
- `KycProfile`/`RiskAssessment` (`domain/kyc.nim`): status KYC, rating risiko dari daftar
  parameter, jadwal re-KYC (`tanggal + bulan` per tingkat; hari dijepit ke akhir bulan).
- `PersonDetail`/`OrgDetail`/`Address` (`domain/detail.nim`, T-078): detail PII orang/lembaga +
  alamat. Validasi teks (panjang, karakter kontrol), `parseSex` (daftar dari parameter),
  `checkDetailKind` (validasi per jenis party: `PERSON` wajib blok `person` & dilarang `org`,
  sebaliknya untuk `ORG`), dan `maskTail` (bentuk tersamar). Sama seperti dokumen identitas:
  **modul tidak menyentuh kriptografi** (ciphertext + blind index dibuat composition root).
- Tidak ada nilai bisnis di kode: format/lebar/prefix CIF, daftar jenis dokumen, tingkat risiko,
  dan jeda re-KYC semuanya parameter DB (spec §10).

## Public API (`api.nim`)

- `cif` — `luhnCheckDigit`, `formatCif`, `maxCifLength`.
- `party` — `PartyKind`, `PartyStatus`, `Party`, `newParty`, `validateName`, `parsePartyKind`.
- `identity` — `IdentityDoc`, `normalizeNumber`, `parseDocType`, `validateNumber`, `maskNumber`.
- `kyc` — `KycStatus`, `KycProfile`, `RiskAssessment`, `parseKycStatus`, `parseRiskLevel`,
  `validateReason`, `reviewMonthsOf`, `reviewDueDate`.
- `detail` — `PersonDetail`, `OrgDetail`, `Address`, `validateLegalName`, `validateOccupation`,
  `validateAddressLine`, `validateCity`, `validatePostalCode`, `parseSex`, `checkDetailKind`,
  `maskTail`.
- `jsonparam` — pembacaan parameter berbentuk larik/peta dengan gagal-cepat.

Orkestrasi transaksi (insert + audit + outbox) ada di composition root `apps/api`, bukan di modul,
karena modul `party` tidak boleh mengimpor internal `platform` (archcheck rule C).

## Event dipublish / dikonsumsi (versi)

- Publish: `party.onboarded` v1 (`{partyId, cif, kind, branchId}`) dan `party.risk_changed` v1
  (`{partyId, ratingId, level, nextReviewDue}`), aggregate `party`.
  **Nama tampil, nomor dokumen, dan detail PII** (nama resmi, tanggal lahir, jenis kelamin,
  pekerjaan, alamat) **tidak pernah ikut** (PII tidak meninggalkan modul).
- Konsumsi: belum ada.

## Parameter key (+ sensitivitas, regulatory_refs)

| Key | Tipe | Scope | Default seed | Sensitivitas |
|---|---|---|---|---|
| `party.cif.format` | string | GLOBAL, INSTITUTION | `{seq:6}{check}` | NORMAL |
| `party.identity.doc_types` | json | GLOBAL, INSTITUTION | `["KTP","NPWP","PASSPORT"]` | NORMAL |
| `party.identity.doc_lengths` | json | GLOBAL, INSTITUTION | `{"KTP":16,"NPWP":15,"PASSPORT":9}` | NORMAL |
| `party.identity.number_max_length` | integer | GLOBAL, INSTITUTION | `32` | NORMAL |
| `party.kyc.risk_levels` | json | GLOBAL, INSTITUTION | `["LOW","MEDIUM","HIGH"]` | NORMAL |
| `party.kyc.default_risk_level` | string | GLOBAL, INSTITUTION | `"LOW"` | NORMAL |
| `party.kyc.review_months` | json | GLOBAL, INSTITUTION | `{"LOW":36,"MEDIUM":12,"HIGH":6}` | NORMAL |
| `party.person.sex_values` | json | GLOBAL, INSTITUTION | `["MALE","FEMALE"]` | NORMAL |

Baris bertanda `NEEDS-COMPLIANCE-REVIEW` di `seeds/params.yaml` (jenis dokumen, panjang nomor,
tingkat risiko, jeda re-KYC) adalah **struktur/kebijakan**, bukan kutipan pasal — register §4 belum
diverifikasi compliance (O-001).

## Tabel & schema

Schema Postgres `party` (`migrations/0001_party_init.sql`, expand-only):

- `party.cif_seq` — sequence nomor urut CIF.
- `party.party` — identitas dasar; `cif` unik, index `branch_id`.
- `party.identity_doc` (`0002`) — dokumen identitas: `number_enc` (ciphertext, CHECK berawalan
  `kran:enc:v1:`), `number_bidx` (blind index hex 64, **unik** per jenis dokumen), `number_last2`
  (bentuk tersamar). Nomor **tidak pernah** plaintext di DB.
- `party.kyc_profile` — satu baris per party: status, rating risiko berjalan, jadwal re-KYC.
- `party.risk_rating` — riwayat penilaian **append-only** (trigger menolak UPDATE/DELETE).
- `party.party_person` (`0041`, T-078) — detail PII orang: `legal_name`/`birth_date`/`sex`/`occupation`,
  tiap field sebagai tiga turunan (ciphertext `_enc`, blind index `_bidx`, bentuk tersamar `_mask`).
- `party.party_org` (`0041`) — detail PII lembaga: `legal_name` (pola sama).
- `party.address` (`0041`) — alamat: `line`/`city`/`postal_code` (pola sama), 1:1 per party untuk
  sekarang (`UNIQUE (party_id)`).

## Task day-close yang didaftarkan

Belum ada. Day-close hanya lewat framework `daycloser` (AGENTS.md §1.7).

## Permission

| Permission | Resource | platform_admin |
|---|---|---|
| `party.party.create` | `party` | ya |
| `party.party.read` | `party` | ya |
| `party.kyc.manage` | `kyc` | ya |
| `party.identity_doc.read` | `identity_doc` | ya |

Katalog di `modules/platform/migrations/0013_platform_rbac_party.sql` (T-070) dan `0014_…party_pii.sql`
(T-071); role teller/CS menyusul. `party.identity_doc.read` **khusus** untuk membuka nomor
(*unmask*) — izin baca biasa tidak cukup, dan setiap pemakaiannya diaudit.

T-078 (detail orang/lembaga + alamat) **memakai ulang** izin yang ada: tulis detail butuh
`party.kyc.manage`, baca tersamar butuh `party.party.read`, dan *unmask* detail butuh
`party.identity_doc.read` + alasan + audit. Tidak ada kode izin baru; pemisahan izin baca PII
yang lebih halus (mis. `party.detail.read`) dicatat sebagai usulan di `docs/tasks/T-078.md`.

## Namespace i18n

Belum ada teks UI modul ini; nanti memakai prefix `party.` (spec §5.5).

## Requirement regulasi terkait (REG-xxx → test)

Tidak ada nomor pasal yang diklaim. Aturan identitas nasabah yang belum terverifikasi tetap
bertanda `NEEDS-COMPLIANCE-REVIEW` di parameter/seed, bukan dikarang di kode (spec §1.8).

## Keputusan & trade-off (link ADR)

- D-046: pilot satu koperasi/satu cabang; `branchId` wajib, tanpa party lintas cabang.
- D-069: penyimpanan dokumen identitas = ciphertext + blind index + bentuk tersamar; duplikat
  dicek lintas party **per jenis dokumen** (`UNIQUE (doc_type, number_bidx)`) — nomor yang sama di
  jenis berbeda bukan duplikat karena tiap jenis punya ruang nomor sendiri; *unmask* = izin khusus
  + alasan + audit; tanpa KEK semua jalur enkripsi menjawab 501 (fail-closed).
- **Rotasi KEK belum punya jalur reindex** blind index (O-073): sampai ada, jangan aktifkan kunci
  baru sebelum `number_bidx` dihitung ulang — kalau tidak, deteksi duplikat gagal-terbuka.
- T-078 memperluas pola D-069 ke **detail PII** (nama resmi, tanggal lahir, jenis kelamin,
  pekerjaan, alamat): tiap kolom sensitif = ciphertext + blind index + bentuk tersamar. AAD =
  nama tabel (bukan `tabel.kolom`), jadi ciphertext antar kolom dalam satu tabel tidak saling
  mengikat — batas yang sama seperti D-069, dicatat di `docs/tasks/T-078.md`.
- T-078 memakai **izin yang ada** (tanpa migrasi `platform`): tulis `party.kyc.manage`, baca
  tersamar `party.party.read`, *unmask* `party.identity_doc.read` + alasan + audit.
- T-078 tanpa KEK: `PUT`/`unmask` menjawab 501 (fail-closed); `GET` tersamar 200 (tidak mendekripsi).
- T-078 menyentuh PII/enkripsi → **HUMAN-REVIEW-REQUIRED** (AGENTS.md §8).
- Respons `GET …/kyc` memuat paling banyak 50 dokumen/riwayat (batas teknis respons, bukan aturan
  bisnis); party pilot punya jauh lebih sedikit, dan riwayat lengkap dibaca dari DB saat audit.
- T-071 menyentuh kriptografi/PII → **HUMAN-REVIEW-REQUIRED** (AGENTS.md §8).
- D-067: pola CIF (prefix/lebar/`{seq:N}`/`{check}`) = parameter `party.cif.format`; algoritme
  check digit Luhn mod 10 = kode (invarian matematis); salah konfigurasi → 500, bukan 400.
- T-070 menunda PII ke T-071 agar tidak ada kolom sensitif lahir plaintext; audit pembacaan PII
  ikut T-071 (T-070 baru mengaudit pembuatan).
- `Idempotency-Key` pada `POST` master data belum ada → O-072 (keputusan lingkup menyusul).

## Menjalankan test

- `./task test tparty` — unit CIF + validasi domain (tanpa DB).
- `./task test itparty` — repo, CIF unik, audit + outbox satu transaksi (butuh DB dev).
- `./task test itapi_party` — jalur HTTP penuh + kontrak OpenAPI (butuh DB dev).
- `./task test tkyc` — unit normalisasi/validasi dokumen + aritmetika re-KYC.
- `./task test itkyc` — ciphertext di kolom DB, blind index, duplikat, riwayat risiko append-only.
- `./task test itapi_kyc` — KYC/dokumen/risiko/*unmask* lewat HTTP + fail-closed tanpa KEK.
- `./task test tdetail` — unit validasi detail + jenis kelamin + validasi per jenis party.
- `./task test itdetail` — detail/alamat di kolom DB (ciphertext, blind index, mask, upsert).
- `./task test itapi_detail` — detail lewat HTTP (200/400/401/403/404/501) + *unmask* + audit.
- `./task check` — archcheck + lint-nomagic + paramgen --check.
