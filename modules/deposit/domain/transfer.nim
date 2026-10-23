## Domain murni modul `deposit` (T-088c): pemindahbukuan (PB) antar rekening simpanan (spec §9.2).
##
## Yang ada di sini hanya bentuk dan invarian struktural: dua rekening **berbeda** dan nominal
## positif. **Tidak ada angka bisnis**: saldo minimum tetap dari binding versi produk
## (`product.savings.min_balance`) yang dibaca composition root, bukan konstanta di kode (spec §10,
## AGENTS.md §1.2).
##
## Batas akuntansi PB dicatat di `MODULE.md` + `docs/ACCEPTED-LIMITS.md`: kedua sisi GL memakai akun
## `201` yang sama, jadi jurnal PB net-nol di buku besar; perpindahan per rekening dicatat di
## `deposit.transfer`.

import kernel/[ids, money]

const
  ## Event ledger yang dipakai posting rule PB (D 201/K 201). Dari data (`ledger.posting_rule`),
  ## migrasi `ledger/0013`; string ini hanya menamai event, bukan aturan akuntansinya.
  transferSourceEvent* = "DepositTransferred" # nomagic:ok nama event ledger, bukan nilai bisnis

type
  ## Baris `deposit.transfer` (cermin kolom DB). Satu baris = satu perpindahan = satu jurnal.
  Transfer* = object
    transferId*: Id
    sourceAccountId*: Id
    destinationAccountId*: Id
    amount*: Money
    businessDate*: string ## ISO `yyyy-MM-dd`
    narration*: string    ## "" = tidak diisi
    journalId*: Id
    createdAt*: string    ## ISO-8601 UTC

proc validateTransfer*(sourceAccountId, destinationAccountId: Id, amount: Money): void =
  ## Invarian PB: rekening sumber dan tujuan **harus berbeda** (memindahkan ke diri sendiri bukan
  ## transaksi) dan nominal **positif** (arah sudah ditentukan sumber→tujuan; nominal <= 0 bukan
  ## perpindahan). Pelanggaran = permintaan tidak sah (400), bukan konflik.
  if $sourceAccountId == $destinationAccountId:
    raise newException(ValueError, "rekening sumber dan tujuan harus berbeda")
  if amount <= zero():
    raise newException(ValueError, "amount harus lebih besar dari nol")
