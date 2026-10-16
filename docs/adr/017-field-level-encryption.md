# ADR-017 — Enkripsi field-level: envelope KEK→DEK turunan + blind index

- **ID**: ADR-017
- **Judul**: Enkripsi field-level (envelope encryption) dengan DEK diturunkan dari KEK
- **Tanggal**: 16 Okt 2026
- **Status**: Diputuskan — **HUMAN-REVIEW-REQUIRED** sebelum dipakai untuk data anggota nyata
  (area kriptografi, AGENTS.md §8; vektor uji independen sudah ada, tetapi ini fondasi baru)

## Konteks

Spec §18.2 mengunci bentuk kontrol at-rest: *"field-level encryption untuk data sensitif (NIK,
NPWP, no. HP, alamat) memakai envelope encryption (KEK dari server/KMS, DEK per tabel/record),
blind index untuk pencarian"*, dan menugaskannya ke modul `platform`. Fase 1 (`party`) akan
mendaratkan NIK/NPWP/no. HP/alamat; menambahkan enkripsi setelah baris ada berarti backfill +
seremoni kunci di bawah tekanan. Pemilik memutuskan ini **bagian fondasi** dan dikerjakan sekarang
(T-054, menutup O-006).

Fakta saat keputusan diambil: **belum ada mekanisme enkripsi field sama sekali** — tidak ada `.nim`
yang menyebut `KRAN_KEK*`/`encryptField`, `KRAN_KEK_FILE` hanya komentar di
`ops/env/kran-prod.env.example`, dan tidak ada `pgp_sym_encrypt` di migrasi. Jadi ini membangun
fondasi, bukan memindahkan yang sudah ada.

Batasan yang mengikat pilihan:

- `nimcrypto == 0.7.3` sudah dependensi tetap (`kran.nimble`, dipakai PBKDF2 sejak D-013).
  **AES ada di `nimcrypto/rijndael.nim`, GCM di `nimcrypto/bcmode.nim`** → AES-256-GCM tersedia
  **tanpa dependensi baru** (tidak ada modul `hkdf`; tidak ada `aes.nim`/`gcm.nim` terpisah).
- Batas arsitektur (`tools/archcheck/lib.nim`): `shared/kernel` hanya stdlib & sesama kernel
  (nimcrypto pihak ketiga = dilarang), `shared/*` boleh diimpor modul mana pun. Karena Fase 1
  `party`/`lending` juga membutuhkannya, mekanisme ditaruh di `shared/platform-lib/`, bukan di
  `modules/platform`.
- Produksi **belum** punya berkas KEK. Menambah keharusan berkas KEK = deploy mati. O-056/D-046
  butir 6: **tanpa fallback diam-diam**.

## Keputusan

Mekanisme di `shared/platform-lib/crypto/fieldcrypto.nim`:

1. **KEK** di berkas terpisah mode 600 (`KRAN_KEK_FILE`), berisi satu atau beberapa kunci berversi
   (`<kid>:<base64 32 byte>`); **kunci aktif = entri terakhir**, kunci lama tetap dibaca untuk
   dekripsi.
2. **DEK per tabel diturunkan** dari KEK: `HMAC-SHA256(KEK, "kran:dek:v1:" || tableName)` — bukan
   disimpan terbungkus di DB.
3. **Cipher self-describing**: `kran:enc:v1:<kid>:<nonce_b64url>:<ciphertext||tag_b64url>`,
   AES-256-GCM, nonce 96-bit acak dari CSPRNG OS (`std/sysrand`), tag 128-bit. **AAD = nama tabel**
   supaya ciphertext tidak bisa dipindahkan antar tabel.
4. **Blind index**: `HMAC-SHA256(kunci_turunan, nilai)` heksadesimal, dengan
   `kunci_turunan = HMAC-SHA256(KEK, "kran:bidx:v1:" || tableName)` — **kunci berbeda** dari kunci
   enkripsi, ber-domain per tabel. Normalisasi field angka (`normalizeDigits`, digit ASCII saja)
   eksplisit di pemanggil; **tidak** mengarang normalisasi Unicode untuk nama/alamat.
5. **Aktivasi**: `KRAN_KEK_FILE` kosong → keyring *belum-terkonfigurasi*, aplikasi start apa adanya;
   setiap enkripsi/dekripsi gagal dengan `NotConfiguredError` ("enkripsi field belum
   dikonfigurasi"). Diset → berkas dibaca & divalidasi **saat startup** (hilang/rusak/kid tidak
   sah/mode bukan 600 → `KekError`, tolak start). Tidak ada fallback diam-diam.
6. Nilai yang gagal dekripsi **selalu** `DecryptError` — tidak pernah mengembalikan plaintext atau
   string kosong. Pesan galat tidak pernah memuat materi kunci maupun plaintext.

**Lingkup**: mekanisme + uji + kontrak pemakaian. **Belum ada kolom PII yang dienkripsi** (users
hanya `username`/`full_name`); kolom nyata dienkripsi saat Fase 1 mendaratkannya. Keyring
divalidasi saat startup biner `api` dan disimpan di `AppContext`; `KRAN_KEK_FILE` kosong = no-op.

## Konsekuensi

- **Positif**: tidak ada materi kunci di dump/backup DB; tidak ada tabel/kopling lintas-modul baru;
  rotasi KEK cukup di berkas (kunci lama tetap untuk baca); mekanisme bisa dipakai modul mana pun
  lewat `shared/`; `kid` di ciphertext membuat dekripsi tetap jalan setelah rotasi.
- **Negatif (jujur)**:
  - Rotasi **tidak bisa independen per tabel**: DEK terikat ke KEK. Mengganti KEK berarti
    re-enkripsi semua field enkripsi lama (kunci lama harus tetap ada selama itu).
  - Mengubah/blind index: rotasi kunci blind index **membatalkan** indeks lama → perlu reindex.
  - Konvensi "kunci aktif = entri terakhir" berarti urutan baris berkas menentukan kunci aktif;
    salah urut = enkripsi baru memakai kunci lain (kunci lama tetap bisa baca, jadi tidak langsung
    rusak, tetapi tidak seperti yang diniatkan). Berkas dikelola tangan — lihat runbook.
  - **KEK hilang = data tak bisa dibaca** (tidak ada pemulihan). Berkas KEK **tidak** ikut backup DB
    dan harus disimpan terpisah/terenkripsi (inti O-006).
  - Uniknya nonce bergantung CSPRNG (96-bit); peluang tabrakan dapat diabaikan untuk volume kita.
  - Blind index membocorkan **kesamaan nilai** (itu memang tujuannya) tetapi bukan nilainya;
    keamanannya bergantung kerahasiaan kunci turunan.

## Alternatif yang ditolak

1. **DEK terbungkus disimpan di tabel registry DB** (envelope per tabel/record, wrapped DEK di DB).
   *Ditolak*: menaruh materi kunci di dump/backup DB — tepat hal yang harus dihindari; menambah
   tabel + kopling lintas-modul; role aplikasi toh bisa membuka bungkusnya, jadi tidak ada
   keuntungan nyata dibanding DEK turunan.
2. **pgcrypto / `pgp_sym_encrypt` di dalam Postgres**. *Ditolak*: kunci melewati SQL/statement log,
   mengikat enkripsi ke privilege DB, sulit diuji & dirotasi, dan melanggar prinsip "tidak ada
   materi kunci di DB"; mengopel kripto ke Postgres.
3. **HKDF-SHA256 penuh** (Extract + Expand, plus implementasi kecil + vektor `crypto.hkdfSync`).
   *Ditolak*: KEK sudah kunci acak seragam 256-bit, sehingga tahap Extract HKDF tidak menambah
   keamanan; `HMAC-SHA256(KEK, info)` adalah inti Expand dan bisa diverifikasi independen dengan
   `crypto.createHmac`. Menambah kode = menambah risiko untuk keuntungan nol di ukuran KEK ini.
4. **Envelope per-record (DEK terenkripsi per baris)**. *Ditolak*: lebih banyak materi tersimpan &
   kompleks untuk manfaat nol pada skala pilot (spec §26.2).

## Bukti / benchmark

- Vektor uji **independen** (bukan keluaran nimcrypto): AES-256-GCM + KDF dihitung dengan Node
  `node:crypto`; perintah pembuatnya dicatat di header `shared/platform-lib/tests/tfieldcrypto.nim`.
  Nimcrypto dan Node menghasilkan ciphertext/tag identik (termasuk plaintext kosong).
- Uji unit `tfieldcrypto.nim`: roundtrip (kosong, multibyte, 100 iterasi), tamper 1 bit
  (ciphertext/tag/nonce/kid/versi), AAD lintas tabel, keyring (hilang/rusak/kid/mode), blind index,
  tidak ada kebocoran plaintext/kunci di pesan galat.
- Uji integrasi `itfieldcrypto.nim` (tabel **sementara**): enkripsi → simpan → cari via blind index
  → dekripsi; nilai tersimpan bukan plaintext; ciphertext yang diubah di DB → gagal eksplisit.
