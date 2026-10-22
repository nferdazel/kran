# Module `product` — Product Factory parametrik

Katalog produk untuk koperasi/BPR/BMT (spec §8, §9, §23). Atribut produk **tidak** ditulis di
kode: setiap nilai adalah binding ke parameter terdaftar, dan perubahan atribut diterbitkan sebagai
**versi baru** yang effective-dated.

## Tabel (migrasi `0001` schema, `0002` katalog, `0003` maker-checker)

| Tabel | Isi |
|---|---|
| `product.product` | Identitas stabil: `code` (unik), `name`, `product_type`. Hanya nama yang boleh diubah. |
| `product.product_version` | `version_no`, `effective_from`, `effective_to`, `status` (`DRAFT`/`ACTIVE`/`REJECTED`), `maker`, `checker`, `approved_at`, `reject_reason`, `sealed`. Rentang **inklusif** `[from, to]`; `EXCLUDE` parsial menolak tumpang tindih **antar versi ACTIVE** (draft bersaing boleh tumpang tindih). Immutable kecuali transisi status sekali dari `DRAFT`, `effective_to` (diisi sekali), dan `sealed` false→true. |
| `product.product_param_binding` | `param_key` → `value` per versi. Immutable. Hanya boleh masuk selama versi `DRAFT`; versi `ACTIVE`/`REJECTED` selalu `sealed` sehingga binding baru ditolak. Minimal satu binding untuk bisa di-approve (ditegakkan trigger saat transisi ke `ACTIVE`). |

Kolom diturunkan dari spec: spec hanya menyebut nama ketiga tabel + aturan effective-dated
(§9.1(5)); keputusan bentuk dicatat **D-076**, maker-checker **D-099** + **D-119**.

## Invarian

- **Tidak ada angka bisnis di kode/DDL.** Tipe, enum, dan batas nilai divalidasi terhadap definisi
  parameter (`platform.param_definition`) di composition root.
- **Maker-checker** (D-099 + D-119): versi lahir `DRAFT`; hanya `DRAFT` → `ACTIVE` (approve) atau
  `DRAFT` → `REJECTED` (reject) yang sah. Reject wajib `reject_reason`. Versi tidak pernah dihapus.
- **Pemisahan tugas** ditegakkan DB: `checker <> maker` (`product_version_self_approval_chk`); approve
  sendiri → 409 `self_approval`.
- **Versi ACTIVE tidak tumpang tindih** (DB `EXCLUDE` parsial); draft yang bertumpang tindih sah —
  tumpang tindih diperiksa saat approve (409 `window_conflict`). Approve menutup versi `ACTIVE`
  sebelumnya sehari sebelum tanggal mulai (`effective_to = tanggalBaru - 1`).
- **Versi immutable**: koreksi/atribut baru = versi baru; `effective_to` hanya diisi sekali;
  himpunan binding dibekukan (`sealed`) saat approve/reject, bukan saat binding pertama masuk.
- **Katalog hanya memuat versi ACTIVE**: `currentVersion`/`openVersion` memfilter `status = 'ACTIVE'`,
  sehingga draft/rejected tidak bocor (T-086, D-119).
- **`btree_gist` dibuat di migrasi `0002`** karena urutan migrasi global menjalankan `product/0002`
  sebelum `platform/0004`; tanpa itu migrasi DB kosong gagal (diverifikasi pada cluster kosong).
- Kunci binding hanya boleh parameter berawalan `product.` (mencegah produk menunjuk parameter
  keamanan/platform).
- Binding ke parameter tak terdaftar/deprecated/di luar batas = **400**, bukan diabaikan.
- Batas schema numerik mengikuti satuan nilai: `money`/`decimal` satuan utuh (×10⁴ minor),
  **`rate` dalam persen** (1% = 10.000 unit) — bukan fraksi 0,01.
- Binding = **snapshot atribut versi itu**: versi baru boleh tidak menyertakan atribut lama
  (berarti atribut itu tidak berlaku pada versi tersebut).

## API

| Endpoint | Izin | Catatan |
|---|---|---|
| `GET /api/v1/products?asOf=` | `product.catalog.read` | Katalog + versi `ACTIVE` yang berlaku pada tanggal itu. |
| `GET /api/v1/products/{code}` | `product.catalog.read` | Detail + semua versi (semua status) + binding. |
| `POST /api/v1/products` | `product.catalog.manage` | Produk + versi 1 `DRAFT` (belum terbit). |
| `POST /api/v1/products/{code}/versions` | `product.catalog.manage` | Ajukan versi baru `DRAFT`; tidak menutup versi ACTIVE berjalan. |
| `POST /api/v1/products/{code}/versions/{versionId}/approve` | `product.catalog.approve` | `DRAFT` → `ACTIVE`; menutup versi ACTIVE sebelumnya; 409 `not_draft`/`self_approval`/`window_conflict`. |
| `POST /api/v1/products/{code}/versions/{versionId}/reject` | `product.catalog.approve` | `DRAFT` → `REJECTED` dengan `reason` wajib (tanpa reason = 400). |

Aksi institusi → dua gerbang: `requirePermission` lalu `authorizedAtBranch(..., "")`; grant
bercabang → 403 `branch_not_allowed`.

## Event

- `ProductPublished` (aggregate `product`) diterbitkan **saat approve** — dalam transaksi yang sama
  dengan perubahan status + audit `product.approve`. Payload: `productId`, `code`, `productType`,
  `versionNo`, `effectiveFrom`.
- Submit (`product.draft`) dan reject (`product.reject`) hanya menulis audit, **tanpa** event.

## Parameter

Katalog atribut untuk pilot (`modules/product/seeds/params.yaml`): `product.savings.min_balance`
(money), `product.savings.admin_fee` (money), `product.savings.grace_period_days` (integer).

Bentuk akrual (O-084/D-094) sudah terdefinisi tetapi **belum bernilai**: `interest_rate` (rate, persen),
`day_count_basis` (`ACT_365|ACT_360|THIRTY_360`), `rounding_mode` (`HALF_UP|HALF_EVEN`),
`rounding_scale` (0–4), `interest_posting` (`NONE|MONTH_END`). Tanpa `default_pack` → binding produk
ke kunci ini gagal-cepat sampai nilainya disetujui compliance. `grace_period_days` belum punya
semantik (T-087); jangan dipakai sebagai konsumen.
**NEEDS-COMPLIANCE-REVIEW**: arti/nilai final menunggu compliance. Rate/day-count/fee lain dicatat
**O-084**.

## Batas

- Maker-checker versi produk **sudah ada** (T-086). Pilot satu operator akan terblokir sampai ada
  penyetuju kedua (`checker <> maker`) — konsekuensi kebijakan, bukan bug (D-099, `ACCEPTED-LIMITS.md`).
- `published_at` kini berarti **waktu pencatatan versi** (saat submit), bukan saat terbit; nama
  historis dipertahankan (utang nama, D-119). Waktu terbit yang sebenarnya = `approved_at`.
- Migrasi `0003` bersifat **destruktif** (`-- dbtools:destructive`): mengganti constraint `EXCLUDE`
  dan menambah kolom `NOT NULL`, jadi **bukan expand-only murni**. Trigger `fill_version_maker`
  menjaga jendela rolling deploy (binary lama menulis tanpa `maker`); dihapus di migrasi contract
  (T-090 di backlog).
- Migrasi platform `0017` memuat grant no-op ke `product.read/manage` (kode lama); grant sebenarnya
  ada di `0018`. Dibiarkan karena `0017` sudah diterapkan (checksum).
- Binding `pvtJson` dibatasi ukuran (16 KiB) tetapi bentuknya belum divalidasi schema; batas schema
  pecahan ditolak (fail-closed), bukan diabaikan. Plafon teknis teks 200 karakter dan `decimal`
  mewarisi 4 desimal `moneyFromString` (**O-087**).
- Migrasi modul ini pernah diubah sebelum deploy (review T-076); DB dev yang dibuat sebelum
  `4930514` harus reset schema `product` + hapus riwayat `product/%` sebelum `dbtools migrate`.
  Jalur DB kosong belum dikunci test otomatis (**O-088**).
- Belum ada UI; pengelolaan lewat API.
