# Modul `deposit` — rekening simpanan

Rekening simpanan anggota (spec §9.2, §23 Fase 2). Nomor rekening dibentuk dari sequence; saldo
disimpan satu baris per rekening sebagai cache untuk operasi teller.

Status: **T-088a** (skema + buka/baca rekening). Setor/tarik/PB + posting jurnal sinkron = **T-088b/**
**T-088c** — belum ada di modul ini.

## Tabel (migrasi `0001` schema+sequence, `0003` rekening)

| Tabel | Isi |
|---|---|
| `deposit.account` | Identitas rekening: `account_no` (unik), `party_id`, `product_id`, `product_version_id`, `branch_id`, `account_type` (`SAVINGS`), `status` (`ACTIVE`/`CLOSED`), `opened_on`. Satu cabang per rekening. |
| `deposit.account_balance` | Satu baris per rekening: `balance numeric(24,4)` dengan CHECK `balance >= 0`. Cache; sumber kebenaran tetap jurnal ledger (spec §9.1(4)). |

`deposit.account_seq` memberi nomor urut rekening. **Nomor berkas tidak berurutan rapat**: tabel
akun ada di `0003`, bukan `0002`, karena urutan migrasi global `(seq, modul, berkas)` menjalankan
`deposit/*` **sebelum** `product/*` pada seq yang sama — sedangkan tabel ini mem-FK
`product.product`/`product.product_version` yang dibuat `product/0002`. `0002` sengaja dilewati
(diverifikasi `./task dbtools validate`). Tabel yang mem-FK `ledger.journal` nanti wajib seq ≥ 4
(`ledger/0003`).

## Invarian

- **Saldo tidak boleh negatif** di DB (`CHECK balance >= 0`) — backstop; operation yang menolak
  saldo negatif ada di jalur tulis (T-088b).
- **Uang tanpa float**: saldo `numeric(24,4)`; di kode lewat tipe `Money` (`kernel/money`), API
  selalu mengirim desimal string 4 desimal.
- **Tanpa kolom `currency`**: asumsi satu mata uang (spec §2.2; T-088 §8 butir 6).
- **`status` hanya `ACTIVE`/`CLOSED`**: `DORMANT`/`FROZEN` belum punya aturan (T-088 §8 butir 8).
- **Ordinary FK** ke `party.party`, `product.product`, `product.product_version`; `branch_id` tanpa
  FK karena belum ada tabel cabang. Kesamaan cabang party↔rekening ditegakkan use case
  (`branch_mismatch`), bukan DB.
- **Nomor rekening provisoris** (D-123): `{seq:10}` zero-padded dari `deposit.account_seq`, **tanpa check
  digit**. Bentuk final (prefix/check digit) menunggu parameter `deposit.account.number_format`
  yang **belum dibuat** (tanpa konsumen di T-088a). Tanda **NEEDS-COMPLIANCE-REVIEW**;
  **jangan mengarang format bisnis lain** sebelum pemilik/compliance memutuskan (T-088 §8 butir 7).

## API

| Endpoint | Izin | Sukses | Error |
|---|---|---|---|
| `POST /api/v1/deposit/accounts` | `deposit.account.manage` | 201 `DepositAccount` | 400 body; 403 (cabang); 409 `party_not_active`/`branch_mismatch`/`product_not_active`; 409 idempotensi |
| `GET /api/v1/deposit/accounts/{accountId}` | `deposit.account.read` | 200 `DepositAccount` | 403 (cabang), 404 |
| `GET /api/v1/deposit/accounts?partyId=` | `deposit.account.read` | 200 `{items:[]}` | 400 uuid, 403 |

- `Idempotency-Key` **wajib** di `POST` (pola T-085: `requireIdempotencyKey`/`withIdempotency`);
  replay 200 + `Idempotent-Replayed: true`, hash beda 409.
- Objek ber-cabang: izin dipegang di cabang rekening (`authorizedAtBranch`). Daftar disaring per
  baris (D-062), bukan 403 seluruh daftar.
- Validasi lintas-modul (party harus ACTIVE dan satu cabang, produk `SAVINGS` dengan versi `ACTIVE`
  berlaku) dilakukan composition root; repo tetap SQL murni.

## Event

Belum ada. Membuka rekening hanya menulis audit `deposit.account.open` (tanpa event outbox): plan
T-088 hanya menyebut event untuk transaksi tunai/PB (T-088b), dan belum ada konsumen untuk
"rekening dibuka" (prinsip: jangan buat semantik tanpa pemakai). Bila kelak dibutuhkan (mis. UI
realtime), tambahkan `deposit.account.opened` + kontrak di `packages/contracts/events`.

## Parameter

Belum ada parameter baru di T-088a (keputusan task: hindari ubahan packs/seed). Saldo minimum dan
batas transaksi ditambahkan bersama konsumennya di T-088b/T-093.

## Batas

- Belum ada transaksi (setor/tarik/PB), posting jurnal, atau UI teller.
- Nomor rekening provisoris (lihat di atas) — **NEEDS-COMPLIANCE-REVIEW**.
- Satu cabang per rekening; pindah cabang belum dimodelkan.
