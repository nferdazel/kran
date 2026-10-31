## Repositori `deposit` pemindahbukuan (T-088c). SQL murni; aturan bisnis di domain + pemanggil.
##
## **Anti-deadlock:** pemanggil mengunci **baris rekening** kedua sisi lebih dulu
## (`lockTransferAccounts`, urutan `account_id` naik), baru baris saldo (`lockBalancesAscending`,
## urutan yang sama). Urutan seragam **rekening → saldo** dipakai semua penulis saldo: jalur tunai
## teller, PB, dan task jatuh tempo. Tanpa kunci rekening, PB memegang saldo sumber lalu menunggu
## `FOR KEY SHARE` di baris rekening (FK `deposit_transfer`) sementara setoran tunai memegang
## rekening dan menunggu saldo — siklus `40P01` (O-112/D-161).
##
## Setelah kedua baris terkunci, urutan UPDATE bebas — dan kegagalan syarat saldo
## (`decreaseBalance`) terjadi **sebelum** saldo tujuan ditambah, sehingga 0 baris tidak
## meninggalkan kredit pada rekening tujuan.
##
## Modul ini sengaja tidak mengimpor internal `platform`/`ledger` (archcheck rule C): jurnal ditulis
## pemanggil (`apps/api`) dalam transaksi yang sama.

import std/options

import db_connector/db_postgres

import kernel/[ids, money, result]
import ../domain/transfer
import ./transaction_repo

const
  transferColumns = "transfer_id, source_account_id, destination_account_id, amount::text, " &
    "to_char(business_date, 'YYYY-MM-DD'), coalesce(narration, ''), journal_id, " &
    "to_char(created_at AT TIME ZONE 'UTC', 'YYYY-MM-DD\"T\"HH24:MI:SS\"Z\"')"

type
  ## Saldo kedua rekening setelah PB diterapkan.
  TransferBalances* = object
    sourceBalanceAfter*: Money
    destinationBalanceAfter*: Money

proc transferOf(row: Row): Transfer =
  Transfer(
    transferId: Id(row[0]),
    sourceAccountId: Id(row[1]),
    destinationAccountId: Id(row[2]),
    amount: moneyFromString(row[3]).value(),
    businessDate: row[4],
    narration: row[5],
    journalId: Id(row[6]),
    createdAt: row[7])

proc lockTransferAccounts*(db: DbConn, sourceId, destinationId: Id) =
  ## Mengunci baris `deposit.account` kedua sisi dalam urutan `account_id` naik, **sebelum** baris
  ## saldo disentuh. Pemanggil wajib membaca ulang status rekening sesudah kunci: nilai yang
  ## dibaca sebelum kunci bisa sudah basi.
  ##
  ## Baris yang tidak ada dilewati; pemanggil yang memetakan rekening hilang ke 404.
  let (first, second) =
    if sourceId < destinationId: (sourceId, destinationId)
    else: (destinationId, sourceId)
  for id in [first, second]:
    discard db.getAllRows(sql"""
      SELECT account_id FROM deposit.account WHERE account_id = ? FOR UPDATE""", $id)

proc lockBalancesAscending(db: DbConn, sourceId, destinationId: Id) =
  ## Kunci kedua baris saldo dalam urutan `account_id` naik (deterministik) supaya dua PB berlawanan
  ## arah tidak saling menunggu. Baris yang tidak ada tetap dilewati di sini; UPDATE berikutnya yang
  ## melaporkannya (baris tujuan hilang = data rusak).
  let (first, second) =
    if sourceId < destinationId: (sourceId, destinationId)
    else: (destinationId, sourceId)
  for id in [first, second]:
    discard db.getAllRows(sql"""
      SELECT account_id FROM deposit.account_balance WHERE account_id = ? FOR UPDATE""", $id)

proc applyTransferBalances*(db: DbConn, sourceId, destinationId: Id,
    amount, minBalance: Money): Option[TransferBalances] =
  ## Kurangi saldo sumber (bersyarat) lalu tambah saldo tujuan, setelah kedua baris terkunci dalam
  ## urutan `account_id` naik (lihat catatan berkas). `none` = saldo sumber tidak cukup → pemanggil
  ## memetakannya ke 409 `insufficient_funds` (tanpa perubahan baris apa pun). Baris saldo tujuan
  ## yang hilang = data rusak → `ValueError` (pemanggil → 500), bukan 409.
  if $sourceId == $destinationId:
    raise newException(ValueError, "rekening sumber dan tujuan harus berbeda")

  lockBalancesAscending(db, sourceId, destinationId)

  let sourceAfter = decreaseBalance(db, sourceId, amount, minBalance)
  if sourceAfter.isNone:
    return none(TransferBalances)
  let destinationAfter = increaseBalance(db, destinationId, amount)
  if destinationAfter.isNone:
    raise newException(ValueError, "baris saldo rekening tujuan tidak ditemukan")
  some(TransferBalances(sourceBalanceAfter: sourceAfter.get(),
    destinationBalanceAfter: destinationAfter.get()))

proc insertTransfer*(db: DbConn, t: Transfer, actor: Id) =
  db.exec(sql"""
    INSERT INTO deposit.transfer
      (transfer_id, source_account_id, destination_account_id, amount, business_date, narration,
       journal_id, created_by)
    VALUES (?, ?, ?, ?::numeric, ?::date, NULLIF(?, ''), ?, ?)""",
    $t.transferId, $t.sourceAccountId, $t.destinationAccountId, t.amount.toDecimalString,
    t.businessDate, t.narration, $t.journalId, $actor)

proc transferById*(db: DbConn, transferId: Id): Option[Transfer] =
  let rows = db.getAllRows(sql("SELECT " & transferColumns &
      " FROM deposit.transfer WHERE transfer_id = ?"), $transferId)
  if rows.len == 0:
    return none(Transfer)
  some(transferOf(rows[0]))

proc transfersByAccount*(db: DbConn, accountId: Id): seq[Transfer] =
  ## Riwayat PB yang menyentuh satu rekening (sebagai sumber atau tujuan), terbaru lebih dulu.
  ## Repo tidak menebak izin; penyaringan cabang dilakukan composition root.
  for row in db.getAllRows(sql("SELECT " & transferColumns &
      """
        FROM deposit.transfer
       WHERE source_account_id = ? OR destination_account_id = ?
       ORDER BY business_date DESC, created_at DESC"""), $accountId, $accountId):
    result.add transferOf(row)

proc transfersForStatement*(db: DbConn, accountId: Id, fromDate, toDate: string,
    limit: int): seq[Transfer] =
  ## Baris PB yang menyentuh satu rekening dalam rentang tanggal (inklusif), urut tanggal **naik**
  ## untuk statement (T-094b). `limit` batas teknis ukuran respons, bukan nilai bisnis.
  for row in db.getAllRows(sql("SELECT " & transferColumns &
      """
        FROM deposit.transfer
       WHERE (source_account_id = ? OR destination_account_id = ?)
         AND business_date >= ?::date
         AND business_date <= ?::date
       ORDER BY business_date, created_at
       LIMIT ?::int"""), $accountId, $accountId, fromDate, toDate, $limit):
    result.add transferOf(row)
