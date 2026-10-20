# Module `product` — Product Factory parametrik

Katalog produk untuk koperasi/BPR/BMT (spec §8, §9, §23). Atribut produk **tidak** ditulis di
kode: setiap nilai adalah binding ke parameter terdaftar, dan perubahan atribut diterbitkan sebagai
**versi baru** yang effective-dated.

## Tabel (migrasi `0001` schema, `0002` katalog)

| Tabel | Isi |
|---|---|
| `product.product` | Identitas stabil: `code` (unik), `name`, `product_type`. Hanya nama yang boleh diubah. |
| `product.product_version` | `version_no`, `effective_from`, `effective_to`, `sealed`. Rentang **inklusif** `[from, to]`; `EXCLUDE` menolak tumpang tindih. Immutable kecuali `effective_to` (diisi sekali) dan `sealed` false→true. |
| `product.product_param_binding` | `param_key` → `value` per versi. Immutable. Minimal satu binding per versi (constraint trigger deferred), lalu versi **di-seal** sehingga binding baru ditolak. |

Kolom diturunkan dari spec: spec hanya menyebut nama ketiga tabel + aturan effective-dated
(§9.1(5)); keputusan bentuk dicatat **D-076**.

## Invarian

- **Tidak ada angka bisnis di kode/DDL.** Tipe, enum, dan batas nilai divalidasi terhadap definisi
  parameter (`platform.param_definition`) di composition root.
- **Versi tidak tumpang tindih** (DB `EXCLUDE`, bukan pengecekan aplikasi).
- **Versi immutable**: koreksi/atribut baru = versi baru; `effective_to` hanya diisi sekali untuk
  menutup versi saat versi berikutnya terbit, dan **himpunan binding dibekukan** (`sealed`) pada
  COMMIT. Versi satu hari sah (`effective_to == effective_from`) — versi baru boleh mulai H+1.
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
| `GET /api/v1/products?asOf=` | `product.catalog.read` | Katalog + versi berlaku pada tanggal itu. |
| `GET /api/v1/products/{code}` | `product.catalog.read` | Detail + semua versi + binding. |
| `POST /api/v1/products` | `product.catalog.manage` | Produk + versi 1 (terbuka). |
| `POST /api/v1/products/{code}/versions` | `product.catalog.manage` | Versi baru; versi terbuka ditutup sehari sebelum tanggal mulai. |

Aksi institusi → dua gerbang: `requirePermission` lalu `authorizedAtBranch(..., "")`; grant
bercabang → 403 `branch_not_allowed`.

## Event

- `ProductPublished` (aggregate `product`) dalam transaksi yang sama dengan versi + audit
  `product.publish`. Payload: `productId`, `code`, `productType`, `versionNo`, `effectiveFrom`.

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

- Belum ada maker-checker untuk perubahan produk (**O-085**); izin `manage` cukup.
- Migrasi platform `0017` memuat grant no-op ke `product.read/manage` (kode lama); grant sebenarnya
  ada di `0018`. Dibiarkan karena `0017` sudah diterapkan (checksum).
- Binding `pvtJson` dibatasi ukuran (16 KiB) tetapi bentuknya belum divalidasi schema; batas schema
  pecahan ditolak (fail-closed), bukan diabaikan. Plafon teknis teks 200 karakter dan `decimal`
  mewarisi 4 desimal `moneyFromString` (**O-087**).
- Migrasi modul ini pernah diubah sebelum deploy (review T-076); DB dev yang dibuat sebelum
  `4930514` harus reset schema `product` + hapus riwayat `product/%` sebelum `dbtools migrate`.
  Jalur DB kosong belum dikunci test otomatis (**O-088**).
- Belum ada UI; pengelolaan lewat API.
- Versi belum punya status DRAFT/RETIRED; semua versi yang tersimpan dianggap terbit.
