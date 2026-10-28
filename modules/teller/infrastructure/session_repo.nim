## Repositori `teller` sesi kas (T-093). SQL murni; aritmetika di domain, kebijakan di composition root.
##
## Invarian DB yang diandalkan di sini:
##   - satu sesi `OPEN` per (cabang, teller) dijaga partial unique index → `insertOpenSession` memakai
##     `ON CONFLICT ... WHERE status = 'OPEN' DO NOTHING` supaya balapan dua buka tidak jadi 500;
##   - vault `FOR UPDATE` implisit lewat `UPDATE ... WHERE balance >= ?` (satu baris per cabang),
##     jadi debit bersyarat tidak punya celah read-then-write;
##   - baris movement immutable (trigger `ledger.reject_mutation()`).
##
## Modul ini tidak mengimpor internal `platform`/`ledger` (archcheck rule C): audit/outbox ditulis
## pemanggil (composition root) dalam transaksi yang sama.

import std/[options, strutils]

import db_connector/db_postgres

import kernel/[ids, money, result]
import ../domain/session

const
  sessionColumns = "session_id, branch_id, teller_user_id, to_char(business_date, 'YYYY-MM-DD'), " &
    "status, opening_float::text, " &
    "to_char(opened_at AT TIME ZONE 'UTC', 'YYYY-MM-DD\"T\"HH24:MI:SS\"Z\"'), opened_by, " &
    "coalesce(expected_cash::text, ''), coalesce(counted_cash::text, ''), " &
    "coalesce(variance::text, ''), coalesce(note, ''), " &
    "coalesce(to_char(closed_at AT TIME ZONE 'UTC', 'YYYY-MM-DD\"T\"HH24:MI:SS\"Z\"'), ''), " &
    "coalesce(closed_by::text, '')"

proc moneyOpt(raw: string): Option[Money] =
  ## Nominal nullable dari DB. Teks kosong = NULL; teks tidak sah = data rusak (ValueError → 500).
  if raw.strip.len == 0:
    return none(Money)
  let parsed = moneyFromString(raw)
  if parsed.isErr:
    raise newException(ValueError, "nominal sesi bukan desimal yang sah: " & raw)
  some(parsed.value())

proc moneyRequired(raw: string): Money =
  let parsed = moneyFromString(raw)
  if parsed.isErr:
    raise newException(ValueError, "nominal bukan desimal yang sah: " & raw)
  parsed.value()

proc sessionOf(row: Row): TellerSession =
  TellerSession(
    sessionId: Id(row[0]),
    branchId: Id(row[1]),
    tellerUserId: Id(row[2]),
    businessDate: row[3],
    status: parseTellerSessionStatus(row[4]),
    openingFloat: moneyRequired(row[5]),
    openedAt: row[6],
    openedBy: Id(row[7]),
    expectedCash: moneyOpt(row[8]),
    countedCash: moneyOpt(row[9]),
    variance: moneyOpt(row[10]),
    note: row[11],
    closedAt: row[12],
    closedBy: row[13])

# --- vault -------------------------------------------------------------------------------------

proc vaultBalanceOf*(db: DbConn, branchId: Id): Option[Money] =
  ## Saldo vault cabang; `none` = vault belum dikonfigurasi (belum pernah diisi seed/runbook).
  let rows = db.getAllRows(
    sql"SELECT balance::text FROM teller.vault WHERE branch_id = ?", $branchId)
  if rows.len == 0:
    return none(Money)
  some(moneyRequired(rows[0][0]))

proc debitVault*(db: DbConn, branchId: Id, amount: Money): Option[Money] =
  ## Kurangi vault **hanya bila** saldonya cukup. `none` = saldo kurang **atau** vault tidak ada;
  ## pemanggil membedakannya lewat `vaultBalanceOf` untuk memilih 409 `insufficient_vault` /
  ## `vault_not_configured`.
  let rows = db.getAllRows(sql"""
      UPDATE teller.vault
         SET balance = balance - ?::numeric, updated_at = now()
       WHERE branch_id = ? AND balance >= ?::numeric
       RETURNING balance::text""", amount.toDecimalString, $branchId, amount.toDecimalString)
  if rows.len == 0:
    return none(Money)
  some(moneyRequired(rows[0][0]))

proc setOpeningVaultBalance*(db: DbConn, branchId: Id, amount: Money): bool =
  ## Menetapkan saldo vault untuk **saldo awal** (T-129/LED-2): hanya bila baris vault belum ada
  ## atau saldonya nol. `false` = vault sudah bersaldo, jadi saldo awal akan menimpa/menggandakan
  ## kas yang sudah tercatat; pemanggil wajib menolak, bukan memaksa.
  ##
  ## Baris vault yang belum ada **dibuat** di sini: perintah saldo awal adalah momen vault cabang
  ## ditetapkan, dan `ledger.journal` untuk event yang sama diposting dalam transaksi yang sama.
  db.execAffectedRows(sql"""
      INSERT INTO teller.vault (branch_id, balance) VALUES (?, ?::numeric)
      ON CONFLICT (branch_id) DO UPDATE
         SET balance = EXCLUDED.balance, updated_at = now()
       WHERE teller.vault.balance = 0""", $branchId, amount.toDecimalString) == 1

proc creditVault*(db: DbConn, branchId: Id, amount: Money): Option[Money] =
  ## Tambah vault sebesar kas fisik yang benar-benar masuk (`counted_cash`, bukan `expected_cash`).
  let rows = db.getAllRows(sql"""
      UPDATE teller.vault
         SET balance = balance + ?::numeric, updated_at = now()
       WHERE branch_id = ?
       RETURNING balance::text""", amount.toDecimalString, $branchId)
  if rows.len == 0:
    return none(Money)
  some(moneyRequired(rows[0][0]))

# --- sesi --------------------------------------------------------------------------------------

proc insertOpenSession*(db: DbConn, s: TellerSession): bool =
  ## Sisipkan sesi `OPEN`. `false` bila sesi `OPEN` lain sudah ada untuk (cabang, teller) — balapan
  ## dua buka diselesaikan index, bukan error DB.
  db.execAffectedRows(sql"""
      INSERT INTO teller.teller_session
        (session_id, branch_id, teller_user_id, business_date, status, opening_float, opened_by,
         note)
      VALUES (?, ?, ?, ?::date, 'OPEN', ?::numeric, ?, NULLIF(?, ''))
      ON CONFLICT (branch_id, teller_user_id) WHERE status = 'OPEN' DO NOTHING""",
    $s.sessionId, $s.branchId, $s.tellerUserId, s.businessDate, s.openingFloat.toDecimalString,
    $s.openedBy, s.note) == 1

proc openSessionCount*(db: DbConn, startsOn, endsOn: string): int64 =
  ## Jumlah sesi kas `OPEN` yang `business_date`-nya di dalam rentang periode. Dipakai gerbang
  ## tutup periode (T-129/LED-1): menutup periode yang memuat sesi OPEN membuat sesi itu tidak
  ## pernah bisa ditutup — jurnal penutupnya ditolak trigger periode, sementara index "satu sesi
  ## OPEN per teller" menghalangi sesi baru.
  result = db.getValue(sql"""
    SELECT count(*)::text FROM teller.teller_session s
     WHERE s.status = 'OPEN'
       AND s.business_date BETWEEN ?::date AND ?::date""", startsOn, endsOn).parseBiggestInt

type
  SessionGate* = object
    ## Rekap sesi yang menghalangi penutupan (spec §11.5 #2): masih `OPEN`, atau sudah `CLOSED`
    ## dengan kas tidak seimbang. `problemIds` dibatasi supaya bukti tidak membengkak.
    openSessions*: int64
    unbalanced*: int64
    problemIds*: seq[string]

proc sessionGate*(db: DbConn, upToDate: string; idLimit = 20): SessionGate =
  ## `upToDate` inklusif: sesi yang masih terbuka dari hari sebelumnya juga menghalangi penutupan
  ## hari ini — justru itu keadaan yang paling perlu dilihat.
  let counts = db.getAllRows(sql"""
    SELECT count(*) FILTER (WHERE status = 'OPEN')::text,
           count(*) FILTER (WHERE status = 'CLOSED' AND variance <> 0)::text
      FROM teller.teller_session
     WHERE business_date <= ?::date""", upToDate)
  if counts.len > 0:
    result.openSessions = parseBiggestInt(counts[0][0]).int64
    result.unbalanced = parseBiggestInt(counts[0][1]).int64
  for row in db.getAllRows(sql"""
      SELECT session_id::text
        FROM teller.teller_session
       WHERE business_date <= ?::date
         AND (status = 'OPEN' OR (status = 'CLOSED' AND variance <> 0))
       ORDER BY business_date, session_id
       LIMIT ?""", upToDate, idLimit):
    result.problemIds.add row[0]

proc sessionById*(db: DbConn, sessionId: Id): Option[TellerSession] =
  let rows = db.getAllRows(
    sql("SELECT " & sessionColumns & " FROM teller.teller_session WHERE session_id = ?"), $sessionId)
  if rows.len == 0:
    return none(TellerSession)
  some(sessionOf(rows[0]))

proc sessionByIdForUpdate*(db: DbConn, sessionId: Id): Option[TellerSession] =
  ## Baca sesi **terkunci** (`FOR UPDATE`). Penutupan bersamaan terserialisasi di baris ini:
  ## penutup kedua menunggu, lalu melihat status `CLOSED` dan ditolak — bukan menambah vault dua kali.
  let rows = db.getAllRows(sql("SELECT " & sessionColumns &
      " FROM teller.teller_session WHERE session_id = ? FOR UPDATE"), $sessionId)
  if rows.len == 0:
    return none(TellerSession)
  some(sessionOf(rows[0]))

proc openSessionFor*(db: DbConn, branchId, tellerUserId: Id): Option[TellerSession] =
  ## Sesi `OPEN` milik satu teller di satu cabang (tanpa lock) — dipakai `GET current` dan
  ## pemeriksaan awal buka.
  let rows = db.getAllRows(sql("SELECT " & sessionColumns &
      """
        FROM teller.teller_session
       WHERE branch_id = ? AND teller_user_id = ? AND status = 'OPEN'"""),
    $branchId, $tellerUserId)
  if rows.len == 0:
    return none(TellerSession)
  some(sessionOf(rows[0]))

proc lockOpenSession*(db: DbConn, branchId, tellerUserId: Id,
                      businessDate: string): Option[TellerSession] =
  ## Gerbang transaksi tunai (093b): kunci sesi `OPEN` hari itu dengan `FOR KEY SHARE`.
  ##
  ## `FOR KEY SHARE` **tidak** memblokir movement baru (FK sudah cukup), tetapi **berkonflik** dengan
  ## `FOR UPDATE` penutupan: penutupan menunggu transaksi tunai in-flight selesai, sehingga movement
  ## yang sedang ditulis tidak hilang dari `expected_cash`. Sebaliknya, setelah penutupan commit,
  ## pembacaan ini melihat status `CLOSED` → 0 baris → 409 (bukan menulis ke sesi tertutup).
  let rows = db.getAllRows(sql("SELECT " & sessionColumns &
      """
        FROM teller.teller_session
       WHERE branch_id = ? AND teller_user_id = ? AND status = 'OPEN' AND business_date = ?::date
       FOR KEY SHARE"""), $branchId, $tellerUserId, businessDate)
  if rows.len == 0:
    return none(TellerSession)
  some(sessionOf(rows[0]))

proc closeSession*(db: DbConn, sessionId: Id, expectedCash, countedCash, variance: Money,
                   note: string, closedBy: Id): bool =
  ## Tutup sesi: hanya berlaku bila masih `OPEN`. `false` = sudah ditutup (tidak ada baris diubah),
  ## jadi pemanggil tidak boleh menambah vault.
  db.execAffectedRows(sql"""
      UPDATE teller.teller_session
         SET status = 'CLOSED', expected_cash = ?::numeric, counted_cash = ?::numeric,
             variance = ?::numeric, note = COALESCE(NULLIF(?, ''), note),
             closed_at = now(), closed_by = ?
       WHERE session_id = ? AND status = 'OPEN'""",
    expectedCash.toDecimalString, countedCash.toDecimalString, variance.toDecimalString, note,
    $closedBy, $sessionId) == 1

# --- cash movement -----------------------------------------------------------------------------

proc insertMovement*(db: DbConn, m: CashMovement) =
  db.exec(sql"""
    INSERT INTO teller.cash_movement
      (movement_id, session_id, movement_type, amount, transaction_id, business_date, created_by)
    VALUES (?, ?, ?, ?::numeric, ?, ?::date, ?)""",
    $m.movementId, $m.sessionId, $m.movementType, m.amount.toDecimalString, $m.transactionId,
    m.businessDate, m.createdBy)

proc movementTotalsOf*(db: DbConn, sessionId: Id): tuple[cashIn, cashOut: Money] =
  ## Agregat arus laci sesi: total setoran dan total penarikan. Satu query per sisi supaya
  ## `expected_cash` dihitung dari jumlah, bukan dari daftar baris yang bisa besar.
  let rows = db.getAllRows(sql"""
      SELECT coalesce(sum(CASE WHEN movement_type = 'CASH_IN' THEN amount ELSE 0 END), 0)::text,
             coalesce(sum(CASE WHEN movement_type = 'CASH_OUT' THEN amount ELSE 0 END), 0)::text
        FROM teller.cash_movement WHERE session_id = ?""", $sessionId)
  (moneyRequired(rows[0][0]), moneyRequired(rows[0][1]))

proc movementsOf*(db: DbConn, sessionId: Id): seq[CashMovement] =
  ## Seluruh movement sesi (urut waktu) — dipakai test paritas/immutability; bukan jalur produksi.
  for row in db.getAllRows(sql"""
      SELECT movement_id, session_id, movement_type, amount::text, transaction_id,
             to_char(business_date, 'YYYY-MM-DD'),
             to_char(occurred_at AT TIME ZONE 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS"Z"'),
             created_by::text
        FROM teller.cash_movement WHERE session_id = ? ORDER BY occurred_at, movement_id""",
      $sessionId):
    result.add CashMovement(
      movementId: Id(row[0]),
      sessionId: Id(row[1]),
      movementType: parseCashMovementType(row[2]),
      amount: moneyRequired(row[3]),
      transactionId: Id(row[4]),
      businessDate: row[5],
      occurredAt: row[6],
      createdBy: row[7])
