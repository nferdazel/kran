## Repositori jurnal (T-073). SQL murni; aturan akuntansi ditegakkan DB (trigger) dan domain.

import std/[options, strutils]

import db_connector/db_postgres

import kernel/[ids, money]
import ../domain/journal

const
  listLimit* = 200 # nomagic:ok batas ukuran respons daftar (bukan nilai bisnis)

proc moneyOf(raw: string): Money =
  ## `numeric(24,4)` → `Money` tanpa float. Skala 4 desimal; lebih dari itu = data rusak (ditolak,
  ## bukan dibulatkan diam-diam).
  let s = raw.strip
  if s.len == 0:
    raise newException(ValueError, "nominal kosong dari DB")
  let negative = s[0] == '-'
  let digits = if negative: s[1 .. ^1] else: s
  let parts = digits.split('.')
  if parts.len > 2:
    raise newException(ValueError, "nominal DB tidak sah: " & raw)
  var frac = if parts.len == 2: parts[1] else: ""
  if frac.len > moneyScale:
    raise newException(ValueError, "nominal DB melebihi 4 desimal: " & raw)
  while frac.len < moneyScale:
    frac.add '0'
  let whole = if parts[0].len == 0: "0" else: parts[0]
  var units = parseBiggestInt(whole) * moneyScaleFactor + parseBiggestInt(frac)
  if negative:
    units = -units
  money(units)

const journalColumns =
  "journal_id, to_char(business_date, 'YYYY-MM-DD'), to_char(value_date, 'YYYY-MM-DD'), " &
    "source_event, source_ref, idempotency_key, coalesce(reversal_of::text, ''), " &
    "to_char(recorded_at AT TIME ZONE 'UTC', 'YYYY-MM-DD\"T\"HH24:MI:SS\"Z\"')"

proc journalOf(row: Row): Journal =
  Journal(
    journalId: Id(row[0]),
    businessDate: row[1],
    valueDate: row[2],
    sourceEvent: row[3],
    sourceRef: Id(row[4]),
    idempotencyKey: row[5],
    reversalOf: row[6],
    recordedAt: row[7],
  )

proc insertJournal*(db: DbConn, j: Journal, createdBy: Id): string =
  ## Menyisipkan header jurnal; `recorded_at` dikembalikan sebagai ISO-8601 UTC. Pelanggaran
  ## idempotensi/trigger = `DbError` yang diterjemahkan pemanggil.
  db.getValue(sql"""
    INSERT INTO ledger.journal
      (journal_id, business_date, value_date, source_event, source_ref, idempotency_key,
       reversal_of, created_by)
    VALUES (?, ?::date, ?::date, ?, ?, ?, NULLIF(?, '')::uuid, ?)
    RETURNING to_char(recorded_at AT TIME ZONE 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS"Z"')""",
    $j.journalId, j.businessDate, j.valueDate, j.sourceEvent, $j.sourceRef,
    j.idempotencyKey, j.reversalOf, $createdBy)

proc insertJournalLine*(db: DbConn, journalId: Id, line: JournalLine) =
  db.exec(sql"""
    INSERT INTO ledger.journal_line (journal_id, line_no, gl_account, branch_id, debit, credit)
    VALUES (?, ?, ?, ?, ?::numeric, ?::numeric)""",
    $journalId, $line.lineNo, line.glAccount, $line.branchId,
    line.debit.toDecimalString, line.credit.toDecimalString)

proc linesOf*(db: DbConn, journalId: Id): seq[JournalLine] =
  for row in db.getAllRows(sql"""
      SELECT line_no, gl_account, branch_id, debit::text, credit::text
        FROM ledger.journal_line WHERE journal_id = ? ORDER BY line_no""", $journalId):
    result.add JournalLine(
      lineNo: parseInt(row[0]),
      glAccount: row[1],
      branchId: Id(row[2]),
      debit: moneyOf(row[3]),
      credit: moneyOf(row[4]))

proc journalById*(db: DbConn, journalId: Id): Option[Journal] =
  let rows = db.getAllRows(
    sql("SELECT " & journalColumns & " FROM ledger.journal WHERE journal_id = ?"), $journalId)
  if rows.len == 0:
    return none(Journal)
  result = some(journalOf(rows[0]))
  result.get().lines = linesOf(db, journalId)

proc journalByIdempotencyKey*(db: DbConn, key: string): Option[Journal] =
  let rows = db.getAllRows(
    sql("SELECT " & journalColumns & " FROM ledger.journal WHERE idempotency_key = ?"), key)
  if rows.len == 0:
    return none(Journal)
  result = some(journalOf(rows[0]))
  result.get().lines = linesOf(db, result.get().journalId)

proc journals*(db: DbConn, businessDate = "", sourceEvent = ""): seq[Journal] =
  ## Daftar header (tanpa baris). Penyaringan di SQL; parameter kosong = tanpa penyaringan.
  for row in db.getAllRows(sql("""
      SELECT """ & journalColumns &
      """
        FROM ledger.journal
       WHERE (NULLIF(?, '')::date IS NULL OR business_date = NULLIF(?, '')::date)
         AND (NULLIF(?, '')::text IS NULL OR source_event = ?)
       ORDER BY business_date DESC, recorded_at DESC, journal_id
       LIMIT ?::int"""), businessDate, businessDate, sourceEvent, sourceEvent, $listLimit):
    result.add journalOf(row)

proc periodOpenFor*(db: DbConn, businessDate: string): bool =
  ## Apakah ada periode OPEN yang memuat tanggal ini. Trigger DB menegakkan hal yang sama; ini
  ## untuk memberi pesan 409 sebelum menulis (bukan pengganti trigger).
  db.getValue(sql"""
    SELECT EXISTS (
      SELECT 1 FROM ledger.period p
       WHERE p.status = 'OPEN' AND ?::date BETWEEN p.starts_on AND p.ends_on)::text""",
    businessDate) == "true"

proc reversalExistsFor*(db: DbConn, journalId: Id): bool =
  db.getValue(sql"""
    SELECT EXISTS (SELECT 1 FROM ledger.journal WHERE reversal_of = ?)::text""",
    $journalId) == "true"
