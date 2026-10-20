# Module `product` — Product Factory parametrik

Katalog produk untuk koperasi/BPR/BMT (spec §8, §9, §23). Atribut produk **tidak** ditulis di
kode: setiap nilai adalah binding ke parameter terdaftar, dan perubahan atribut diterbitkan sebagai
**versi baru** yang effective-dated.

## Tabel (migrasi `0001` schema, `0002` katalog)

| Tabel | Isi |
|---|---|
| `product.product` | Identitas stabil: `code` (unik), `name`, `product_type`. Hanya nama yang boleh diubah. |
| `product.product_version` | `version_no`, `effective_from`, `effective_to`, status terbit. Rentang **inklusif** `[from, to]`; `EXCLUDE` menolak tumpang tindih. Immutable kecuali `effective_to` (diisi sekali). |
| `product.product_param_binding` | `param_key` → `value` per versi. Immutable. Minimal satu binding per versi (constraint trigger deferred). |

Kolom diturunkan dari spec: spec hanya menyebut nama ketiga tabel + aturan effective-dated
(§9.1(5)); keputusan bentuk dicatat **D-076**.

## Invarian

- **Tidak ada angka bisnis di kode/DDL.** Tipe, enum, dan batas nilai divalidasi terhadap definisi
  parameter (`platform.param_definition`) di composition root.
- **Versi tidak tumpang tindih** (DB `EXCLUDE`, bukan pengecekan aplikasi).
- **Versi immutable**: koreksi/atribut baru = versi baru; `effective_to` hanya diisi sekali untuk
  menutup versi saat versi berikutnya terbit.
- Kunci binding hanya boleh parameter berawalan `product.` (mencegah produk menunjuk parameter
  keamanan/platform).
- Binding ke parameter tak terdaftar/deprecated/di luar batas = **400**, bukan diabaikan.

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
**NEEDS-COMPLIANCE-REVIEW**: arti/nilai final menunggu compliance. Rate/day-count/fee lain dicatat
**O-084**.

## Batas

- Belum ada maker-checker untuk perubahan produk (**O-085**); izin `manage` cukup.
- Belum ada UI; pengelolaan lewat API.
- Versi belum punya status DRAFT/RETIRED; semua versi yang tersimpan dianggap terbit.
