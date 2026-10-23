## Repositori `deposit` (T-088a). SQL murni; tidak ada aturan bisnis di sini.
##
## Modul ini sengaja tidak mengimpor internal `platform` (archcheck rule C): audit/outbox ditulis
## pemanggil (composition root `apps/api`) dalam transaksi yang sama.

import std/[options, strutils]

import db_connector/db_postgres

import kernel/[ids, money, result]
import ../domain/account

const
  ## Kolom akun + kode produk (join) + saldo (kiri, boleh kosong untuk baris lama) + klasifikasi
  ## simpanan produk (T-111; `''` = belum terklasifikasi). Saldo disimpan `numeric(24,4)`; dibaca
  ## sebagai teks desimal lalu diparse `moneyFromString` (tanpa float).
  accountColumns = "a.account_id, a.account_no, a.party_id, a.product_id, " &
    "a.product_version_id, p.code, a.branch_id, a.account_type, a.status, " &
    "to_char(a.opened_on, 'YYYY-MM-DD'), " &
    "to_char(a.created_at AT TIME ZONE 'UTC', 'YYYY-MM-DD\"T\"HH24:MI:SS\"Z\"'), " &
    "coalesce(b.balance::text, '0.0000'), coalesce(p.savings_kind, '')"

proc accountOf(row: Row): Account =
  let parsedBalance = moneyFromString(row[11])
  if parsedBalance.isErr:
    raise newException(ValueError, "saldo rekening bukan desimal yang sah: " & row[11])
  Account(
    accountId: Id(row[0]),
    accountNo: row[1],
    partyId: Id(row[2]),
    productId: Id(row[3]),
    productVersionId: Id(row[4]),
    productCode: row[5],
    branchId: Id(row[6]),
    accountType: parseAccountType(row[7]),
    status: parseAccountStatus(row[8]),
    openedOn: row[9],
    createdAt: row[10],
    balance: parsedBalance.value(),
    savingsKind: row[12],
  )

proc nextAccountSeq*(db: DbConn): int64 =
  ## Nomor urut rekening berikutnya. Sequence boleh berlubang bila transaksi batal — nomor bisnis
  ## tidak boleh dipakai ulang (spec §9.1(8)).
  int64(parseInt(db.getValue(sql"SELECT nextval('deposit.account_seq')::text")))

proc insertAccount*(db: DbConn, a: Account, actor: Id) =
  ## Menyisipkan rekening **dan** baris saldo awalnya dalam satu transaksi pemanggil.
  db.exec(sql"""
    INSERT INTO deposit.account
      (account_id, account_no, party_id, product_id, product_version_id, branch_id,
       account_type, status, opened_on, created_by, updated_by)
    VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?::date, ?, ?)""",
    $a.accountId, a.accountNo, $a.partyId, $a.productId, $a.productVersionId, $a.branchId,
    $a.accountType, $a.status, a.openedOn, $actor, $actor)
  db.exec(sql"""
    INSERT INTO deposit.account_balance (account_id, balance)
    VALUES (?, ?::numeric)""", $a.accountId, a.balance.toDecimalString())

proc accountById*(db: DbConn, accountId: Id): Option[Account] =
  let rows = db.getAllRows(sql("SELECT " & accountColumns &
      """
        FROM deposit.account a
        JOIN product.product p ON p.product_id = a.product_id
        LEFT JOIN deposit.account_balance b ON b.account_id = a.account_id
       WHERE a.account_id = ?"""), $accountId)
  if rows.len == 0:
    return none(Account)
  some(accountOf(rows[0]))

proc accountByNo*(db: DbConn, accountNo: string): Option[Account] =
  ## Satu rekening dari nomor (UNIQUE). Penyaringan cabang tetap tugas pemanggil.
  let rows = db.getAllRows(sql("SELECT " & accountColumns &
      """
        FROM deposit.account a
        JOIN product.product p ON p.product_id = a.product_id
        LEFT JOIN deposit.account_balance b ON b.account_id = a.account_id
       WHERE a.account_no = ?"""), accountNo)
  if rows.len == 0:
    return none(Account)
  some(accountOf(rows[0]))

proc accountsByParty*(db: DbConn, partyId: Id): seq[Account] =
  ## Semua rekening milik satu party, urut nomor rekening. Penyaringan cabang dilakukan pemanggil
  ## (composition root) per baris — repo tidak menebak izin.
  for row in db.getAllRows(sql("SELECT " & accountColumns &
      """
        FROM deposit.account a
        JOIN product.product p ON p.product_id = a.product_id
        LEFT JOIN deposit.account_balance b ON b.account_id = a.account_id
       WHERE a.party_id = ?
       ORDER BY a.account_no"""), $partyId):
    result.add accountOf(row)
