## Repositori `deposit` transaksi tunai (T-088b). SQL murni; aturan bisnis di domain + pemanggil.
##
## Mutasi saldo memakai **satu `UPDATE` bersyarat** pada baris `deposit.account_balance`:
##   - setor: `balance = balance + ?`
##   - tarik: `balance = balance - ? WHERE balance - ? >= min_balance`
## 0 baris = syarat tidak terpenuhi (saldo kurang / baris saldo hilang) → `none`; pemanggil
## memetakannya ke 409. Baris terkunci otomatis oleh UPDATE, jadi dua koneksi bersamaan
## terserialisasi (tidak ada celah read-then-write). CHECK `balance >= 0` tetap backstop DB.
##
## Modul ini sengaja tidak mengimpor internal `platform`/`ledger` (archcheck rule C): jurnal ditulis
## pemanggil (`apps/api`) dalam transaksi yang sama.

import std/options

import db_connector/db_postgres

import kernel/[ids, money, result]
import ../domain/transaction

const
  transactionColumns = "transaction_id, tx_type, account_id, amount::text, " &
    "to_char(business_date, 'YYYY-MM-DD'), coalesce(narration, ''), journal_id, " &
    "to_char(created_at AT TIME ZONE 'UTC', 'YYYY-MM-DD\"T\"HH24:MI:SS\"Z\"')"

proc transactionOf(row: Row): Transaction =
  Transaction(
    transactionId: Id(row[0]),
    txType: parseTransactionType(row[1]),
    accountId: Id(row[2]),
    amount: moneyFromString(row[3]).value(),
    businessDate: row[4],
    narration: row[5],
    journalId: Id(row[6]),
    createdAt: row[7])

proc increaseBalance*(db: DbConn, accountId: Id, amount: Money): Option[Money] =
  ## Setor: saldo + nominal. `none` = baris saldo tidak ada (rekening tanpa `account_balance`).
  let rows = db.getAllRows(sql"""
      UPDATE deposit.account_balance
         SET balance = balance + ?::numeric, updated_at = now()
       WHERE account_id = ?
       RETURNING balance::text""", amount.toDecimalString, $accountId)
  if rows.len == 0:
    return none(Money)
  some(moneyFromString(rows[0][0]).value())

proc decreaseBalance*(db: DbConn, accountId: Id, amount, minBalance: Money): Option[Money] =
  ## Tarik: saldo - nominal **hanya bila** hasilnya `>= minBalance`. `none` = saldo tidak cukup
  ## (atau baris saldo tidak ada). Saldo minimum datang dari binding versi produk (pemanggil).
  let rows = db.getAllRows(sql"""
      UPDATE deposit.account_balance
         SET balance = balance - ?::numeric, updated_at = now()
       WHERE account_id = ?
         AND balance - ?::numeric >= ?::numeric
       RETURNING balance::text""",
    amount.toDecimalString, $accountId, amount.toDecimalString, minBalance.toDecimalString)
  if rows.len == 0:
    return none(Money)
  some(moneyFromString(rows[0][0]).value())

proc insertTransaction*(db: DbConn, tx: Transaction, actor: Id) =
  db.exec(sql"""
    INSERT INTO deposit.transaction
      (transaction_id, tx_type, account_id, amount, business_date, narration, journal_id, created_by)
    VALUES (?, ?, ?, ?::numeric, ?::date, NULLIF(?, ''), ?, ?)""",
    $tx.transactionId, $tx.txType, $tx.accountId, tx.amount.toDecimalString, tx.businessDate,
    tx.narration, $tx.journalId, $actor)

proc transactionById*(db: DbConn, transactionId: Id): Option[Transaction] =
  let rows = db.getAllRows(sql("SELECT " & transactionColumns &
      " FROM deposit.transaction WHERE transaction_id = ?"), $transactionId)
  if rows.len == 0:
    return none(Transaction)
  some(transactionOf(rows[0]))

proc transactionsByAccount*(db: DbConn, accountId: Id): seq[Transaction] =
  ## Riwayat transaksi satu rekening, terbaru lebih dulu. Repo tidak menebak izin; penyaringan
  ## cabang dilakukan composition root.
  for row in db.getAllRows(sql("SELECT " & transactionColumns &
      """
        FROM deposit.transaction
       WHERE account_id = ?
       ORDER BY business_date DESC, created_at DESC"""), $accountId):
    result.add transactionOf(row)

proc transactionsForStatement*(db: DbConn, accountId: Id, fromDate, toDate: string,
    limit: int): seq[Transaction] =
  ## Baris transaksi tunai satu rekening dalam rentang tanggal (inklusif), urut tanggal **naik**
  ## untuk statement (T-094b). Subledger: tidak ada perhitungan saldo berjalan di sini. `limit`
  ## adalah batas teknis ukuran respons, bukan nilai bisnis.
  for row in db.getAllRows(sql("SELECT " & transactionColumns &
      """
        FROM deposit.transaction
       WHERE account_id = ?
         AND business_date >= ?::date
         AND business_date <= ?::date
       ORDER BY business_date, created_at
       LIMIT ?::int"""), $accountId, fromDate, toDate, $limit):
    result.add transactionOf(row)
