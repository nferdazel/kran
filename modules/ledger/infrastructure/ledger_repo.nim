## Repositori `ledger` untuk COA & periode (T-072). SQL murni, tanpa aturan bisnis.
##
## Modul tidak mengimpor internal `platform` (archcheck rule C): audit/outbox ditulis composition
## root (`apps/api`) dalam transaksi yang sama.

import std/options

import db_connector/db_postgres

import kernel/ids
import ../domain/[coa, period]

const
  ## Batas ukuran daftar (pertahanan terhadap permintaan besar) — angka **teknis**, bukan aturan
  ## bisnis. COA pilot puluhan baris; daftar periode bertambah satu per bulan.
  listLimit* = 200 # nomagic:ok batas ukuran respons, bukan nilai bisnis

const coaColumns =
  "account_id, code, name, account_type, normal_side, postable, status, " &
    "to_char(created_at AT TIME ZONE 'UTC', 'YYYY-MM-DD\"T\"HH24:MI:SS\"Z\"')"

proc coaOf(row: Row): CoaAccount =
  let accountType = parseAccountType(row[3])
  if accountType.isNone:
    raise newException(ValueError, "account_type di DB tidak dikenal: " & row[3])
  let status = parseAccountStatus(row[6])
  if status.isNone:
    raise newException(ValueError, "status COA di DB tidak dikenal: " & row[6])
  CoaAccount(
    accountId: Id(row[0]),
    code: row[1],
    name: row[2],
    accountType: accountType.get(),
    normalSide: if row[4] == "DEBIT": nsDebit else: nsCredit,
    postable: row[5] == "t",
    status: status.get(),
    createdAt: row[7],
  )

proc insertCoa*(db: DbConn, a: CoaAccount, createdBy: Id): string =
  ## Menyisipkan akun COA dan mengembalikan `created_at` ISO-8601 UTC. Kode duplikat =
  ## `DbError` (constraint `coa_code_uq`) yang diterjemahkan pemanggil jadi 409.
  db.getValue(sql"""
    INSERT INTO ledger.coa_account
      (account_id, code, name, account_type, normal_side, postable, status, created_by, updated_by)
    VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
    RETURNING to_char(created_at AT TIME ZONE 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS"Z"')""",
    $a.accountId, a.code, a.name, $a.accountType, $a.normalSide, a.postable, $a.status,
    $createdBy, $createdBy)

proc coaByCode*(db: DbConn, code: string): Option[CoaAccount] =
  let rows = db.getAllRows(
    sql("SELECT " & coaColumns & " FROM ledger.coa_account WHERE code = ?"), code)
  if rows.len == 0:
    return none(CoaAccount)
  some(coaOf(rows[0]))

proc coaAccounts*(db: DbConn, accountType = "", postable = ""): seq[CoaAccount] =
  ## Daftar akun; `accountType` (`ASSET`…) dan `postable` (`true`/`false`) menyaring bila diisi.
  ## Penyaringan dilakukan di SQL, bukan setelah `LIMIT`, supaya hasil tidak terpotong diam-diam.
  ## Parameter kosong = tanpa penyaringan (`NULLIF`, bukan perakitan SQL).
  for row in db.getAllRows(sql("""
    SELECT """ & coaColumns & """
      FROM ledger.coa_account
     WHERE (NULLIF(?, '')::text IS NULL OR account_type = ?)
       AND (NULLIF(?, '')::boolean IS NULL OR postable = NULLIF(?, '')::boolean)
     ORDER BY code LIMIT ?::int"""),
      accountType, accountType, postable, postable, $listLimit):
    result.add coaOf(row)

const periodColumns =
  "period_id, to_char(starts_on, 'YYYY-MM-DD'), to_char(ends_on, 'YYYY-MM-DD'), status, " &
    "coalesce(to_char(closed_at AT TIME ZONE 'UTC', 'YYYY-MM-DD\"T\"HH24:MI:SS\"Z\"'), ''), " &
    "coalesce(closed_by::text, ''), " &
    "to_char(created_at AT TIME ZONE 'UTC', 'YYYY-MM-DD\"T\"HH24:MI:SS\"Z\"')"

proc periodOf(row: Row): Period =
  let status = parsePeriodStatus(row[3])
  if status.isNone:
    raise newException(ValueError, "status periode di DB tidak dikenal: " & row[3])
  Period(
    periodId: Id(row[0]),
    startsOn: row[1],
    endsOn: row[2],
    status: status.get(),
    closedAt: row[4],
    closedBy: row[5],
    createdAt: row[6],
  )

proc insertPeriod*(db: DbConn, p: Period, createdBy: Id): string =
  ## Membuka periode baru. Tumpang tindih = `DbError` (EXCLUDE `period_no_overlap`) yang
  ## diterjemahkan pemanggil jadi 409.
  db.getValue(sql"""
    INSERT INTO ledger.period (period_id, starts_on, ends_on, status, created_by, updated_by)
    VALUES (?, ?::date, ?::date, 'OPEN', ?, ?)
    RETURNING to_char(created_at AT TIME ZONE 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS"Z"')""",
    $p.periodId, p.startsOn, p.endsOn, $createdBy, $createdBy)

proc periodById*(db: DbConn, periodId: Id): Option[Period] =
  let rows = db.getAllRows(
    sql("SELECT " & periodColumns & " FROM ledger.period WHERE period_id = ?"), $periodId)
  if rows.len == 0:
    return none(Period)
  some(periodOf(rows[0]))

proc periods*(db: DbConn): seq[Period] =
  for row in db.getAllRows(sql("SELECT " & periodColumns &
      " FROM ledger.period ORDER BY starts_on DESC LIMIT ?::int"), $listLimit):
    result.add periodOf(row)

proc closePeriod*(db: DbConn, periodId: Id, closedBy: Id): string =
  ## Menutup periode OPEN dan mengembalikan `closed_at` ISO-8601 UTC. **Hasil kosong** berarti
  ## UPDATE mengenai 0 baris: periode sudah ditutup transaksi lain (balapan) atau statusnya bukan
  ## OPEN. Pemanggil wajib memperlakukannya sebagai 409 dan **tidak** menulis audit/event.
  db.getValue(sql"""
    UPDATE ledger.period
       SET status = 'CLOSED', closed_at = now(), closed_by = ?, updated_at = now(), updated_by = ?
     WHERE period_id = ? AND status = 'OPEN'
    RETURNING to_char(closed_at AT TIME ZONE 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS"Z"')""",
    $closedBy, $closedBy, $periodId)
