## Repository parameter: baca (resolusi) + tulis (maker-checker) + NOTIFY (spec §10.2, §10.4).
##
## Semua nilai bisnis ada di DB; modul ini tidak menyimpan default apa pun. Bila nilai aktif
## tidak ditemukan, hasilnya `none` — **pemanggil** yang mengubahnya jadi `ParamNotFound`
## (spec §10.6: tidak ada fallback diam-diam).
##
## `db_connector` tidak membungkus `LISTEN/NOTIFY`, jadi bagian itu memakai libpq langsung
## (`pqconsumeInput`/`pqnotifies`) — terkurung di berkas ini.

import std/[json, options, strutils, times, os]
import db_connector/db_postgres
import db_connector/postgres

import ../domain/[audit, event, param]
import ./audit_repo
import ./outbox_repo
import kernel/[auditcontext, clock, ids, paramkey]

const
  ## Kanal NOTIFY untuk invalidasi cache in-proc (spec §10.4). Satu kanal untuk semua key:
  ## kunci cache sudah memuat key + scope + tanggal, jadi invalidasi selektif tak diperlukan.
  notifyChannel* = "platform_param_changed"

  ## Nilai yang berlaku pada `as_of`. Termasuk baris `SUPERSEDED` — periode riwayatnya tetap
  ## satu-satunya nilai pada tanggal lampau (`approveValue` memangkas `effective_to`-nya).
  activeValueSql = """
SELECT param_value_id::text, scope_type, coalesce(scope_id, ''), value::text,
       to_char(effective_from, 'YYYY-MM-DD'), coalesce(to_char(effective_to, 'YYYY-MM-DD'), '')
  FROM platform.param_value
 WHERE key = ? AND status IN ('ACTIVE', 'SUPERSEDED')
   AND effective_from <= ?::date
   AND (effective_to IS NULL OR effective_to > ?::date)"""

proc parseScopeType*(s: string): ParamScopeType =
  for t in ParamScopeType:
    if $t == s:
      return t
  raise newException(ValueError, "scope_type tidak dikenal: " & s)

proc parseStatus*(s: string): ParamStatus =
  for st in ParamStatus:
    if $st == s:
      return st
  raise newException(ValueError, "status parameter tidak dikenal: " & s)

proc parseValueType*(s: string): ParamValueType =
  for t in ParamValueType:
    if $t == s:
      return t
  raise newException(ValueError, "value_type tidak dikenal: " & s)

proc parseSensitivity*(s: string): ParamSensitivity =
  for s2 in ParamSensitivity:
    if $s2 == s:
      return s2
  raise newException(ValueError, "sensitivity tidak dikenal: " & s)

proc singleRow*(db: DbConn, q: SqlQuery, args: varargs[string, `$`]): Option[Row] =
  ## Catatan jebakan `db_connector`: `getRow` mengembalikan Row **berisi kolom kosong** bila
  ## hasilnya nol baris (bukan Row kosong), sehingga "tidak ditemukan" tidak bisa dideteksi
  ## dari `row.len`. Modul ini memakai `getAllRows` supaya jelas.
  let rows = db.getAllRows(q, args)
  if rows.len == 0:
    none(Row)
  else:
    some(rows[0])

proc pgArrayItems(raw: string): seq[string] =
  for item in raw.strip(chars = {'{', '}'}).split(','):
    let s = item.strip()
    if s.len > 0:
      result.add s

proc candidatesOf*(db: DbConn, key: string, asOf: string): seq[ParamCandidate] =
  ## Semua nilai yang berlaku untuk satu key pada `asOf` (ACTIVE atau riwayat SUPERSEDED
  ## yang periodenya menutup tanggal itu).
  for row in db.getAllRows(sql(activeValueSql), key, asOf, asOf):
    result.add ParamCandidate(
      paramValueId: row[0],
      scopeType: parseScopeType(row[1]),
      scopeId: row[2],
      value: parseJson(row[3]),
      effectiveFrom: row[4],
      effectiveTo: row[5])

type
  DefinitionRow* = object
    key*: string
    module*: string
    valueType*: ParamValueType
    schema*: JsonNode
    allowedScopes*: seq[ParamScopeType]
    sensitivity*: ParamSensitivity
    requiresApproval*: bool
    descriptionKey*: string
    regulatoryRefs*: seq[string]
    deprecated*: bool

proc definitionOf*(db: DbConn, key: string): Option[DefinitionRow] =
  let found = db.singleRow(sql"""
    SELECT key, module, value_type, json_schema::text, allowed_scopes, sensitivity,
           requires_approval, description_key, regulatory_refs, deprecated
      FROM platform.param_definition WHERE key = ?""", key)
  if found.isNone:
    return none(DefinitionRow)
  let row = found.get()
  var scopes: seq[ParamScopeType]
  for s in pgArrayItems(row[4]):
    scopes.add parseScopeType(s)
  some DefinitionRow(
    key: row[0], module: row[1], valueType: parseValueType(row[2]),
    schema: parseJson(row[3]), allowedScopes: scopes, sensitivity: parseSensitivity(row[5]),
    requiresApproval: row[6] == "t", descriptionKey: row[7],
    regulatoryRefs: pgArrayItems(row[8]), deprecated: row[9] == "t")

proc notifyChange*(db: DbConn, key: string) =
  ## `NOTIFY` ikut transaksi berjalan (Postgres mengirimnya saat commit).
  db.exec(sql("NOTIFY " & notifyChannel & ", ?"), key)

proc listenChanges*(db: DbConn) =
  ## `LISTEN` kanal perubahan parameter — dipanggil sekali per koneksi pendengar.
  db.exec(sql("LISTEN " & notifyChannel))

proc pollChanges*(db: DbConn, timeoutMs: int, pollIntervalMs = 20): seq[string] =
  ## Menunggu notifikasi kanal ini sampai `timeoutMs`. Mengembalikan daftar key yang berubah.
  let deadline = epochTime() * 1000.0 + float(timeoutMs)
  while true:
    discard pqconsumeInput(db)
    var notif = pqnotifies(db)
    while not notif.isNil:
      let channel = $notif.relname
      let payload = $notif.extra
      pqfreemem(notif)
      if channel == notifyChannel and payload.len > 0:
        result.add payload
      notif = pqnotifies(db)
    if result.len > 0 or epochTime() * 1000.0 >= deadline:
      return
    sleep(pollIntervalMs)

proc rowStatus*(db: DbConn, paramValueId: string): string =
  db.getValue(sql"SELECT status FROM platform.param_value WHERE param_value_id = ?::uuid",
    paramValueId)

proc paramValueId*(db: DbConn, key, scopeType, scopeId, effectiveFrom: string): string =
  ## Mencari id nilai untuk (key, scope, effective_from) — dipakai test & UI nanti.
  if scopeId.len == 0:
    db.getValue(sql"""
      SELECT param_value_id::text FROM platform.param_value
       WHERE key = ? AND scope_type = ? AND scope_id IS NULL AND effective_from = ?::date""",
      key, scopeType, effectiveFrom)
  else:
    db.getValue(sql"""
      SELECT param_value_id::text FROM platform.param_value
       WHERE key = ? AND scope_type = ? AND scope_id = ? AND effective_from = ?::date""",
      key, scopeType, scopeId, effectiveFrom)

type
  SubmitResult* = object
    paramValueId*: string
    status*: ParamStatus ## selalu PENDING: aktivasi butuh orang kedua (checker ≠ maker)

proc submitValue*(db: DbConn, paramValueId, key, scopeType, scopeId: string,
                  value: JsonNode, effectiveFrom: string, effectiveTo: string,
                  maker: Id, reason: string): SubmitResult =
  ## Mengajukan nilai baru (maker) berstatus PENDING.
  ## Skema menolak `checker = maker`, jadi tidak ada jalur "langsung ACTIVE" oleh satu orang —
  ## parameter NORMAL maupun CRITICAL sama-sama butuh persetujuan orang lain (spec §10.2/§10.4).
  ##
  ## Ditegakkan di sini (defense in depth, spec §10.4): key harus terdaftar, `scope_type` harus
  ## diizinkan definisi, dan nilai harus cocok schema + bentuk tipe.
  let def = definitionOf(db, key)
  if def.isNone:
    raise newException(ValueError, "definisi parameter tidak dikenal: " & key)
  if parseScopeType(scopeType) notin def.get().allowedScopes:
    raise newException(ValueError,
      "scope " & scopeType & " tidak diizinkan untuk " & key & " (allowed: " &
      $def.get().allowedScopes & ")")
  if not valueMatchesType(def.get().valueType, value):
    raise newException(ValueError, "nilai " & key & " harus " &
      typeShapeMessage(def.get().valueType))
  let schemaProblem = validateAgainstSchema(def.get().schema, value)
  if schemaProblem.len > 0:
    raise newException(ValueError, "nilai " & key & " melanggar schema: " & schemaProblem)
  db.exec(sql"""
    INSERT INTO platform.param_value
      (param_value_id, key, scope_type, scope_id, value, effective_from, effective_to,
       status, maker, reason)
    VALUES (?::uuid, ?, ?, NULLIF(?, ''), ?::jsonb, ?::date, NULLIF(?, '')::date,
            'PENDING', ?::uuid, ?)""",
    paramValueId, key, scopeType, scopeId, $value, effectiveFrom, effectiveTo, $maker, reason)
  SubmitResult(paramValueId: paramValueId, status: pvPending)

proc approveValue*(db: DbConn, paramValueId: string, checker: Id): bool =
  ## Menyetujui nilai (checker) → ACTIVE. Mengembalikan `false` bila nilainya tidak PENDING.
  ## Baris ACTIVE sebelumnya pada (key, scope) yang sama dan mulai lebih awal dipangkas
  ## (`SUPERSEDED`, `effective_to` = `effective_from` baru) — pola supersede, bukan tumpang tindih.
  ## Raise `DbError` bila periode baru menabrak ACTIVE lain (EXCLUDE) atau `checker = maker`.
  if db.getValue(sql"SELECT status FROM platform.param_value WHERE param_value_id = ?::uuid",
      paramValueId) != "PENDING":
    return false
  discard db.execAffectedRows(sql"""
    UPDATE platform.param_value o
       SET status = 'SUPERSEDED', effective_to = n.effective_from
      FROM platform.param_value n
     WHERE n.param_value_id = ?::uuid
       AND o.key = n.key AND o.scope_type = n.scope_type
       AND coalesce(o.scope_id, '') = coalesce(n.scope_id, '')
       AND o.status = 'ACTIVE'
       AND o.param_value_id <> n.param_value_id
       AND o.effective_from < n.effective_from
       AND (o.effective_to IS NULL OR o.effective_to > n.effective_from)""", paramValueId)
  db.execAffectedRows(sql"""
    UPDATE platform.param_value SET status = 'ACTIVE', checker = ?::uuid
     WHERE param_value_id = ?::uuid""", $checker, paramValueId) == 1

proc rejectValue*(db: DbConn, paramValueId: string, checker: Id, reason: string): bool =
  db.execAffectedRows(sql"""
    UPDATE platform.param_value
       SET status = 'REJECTED', checker = ?::uuid, reason = reason || ' | ditolak: ' || ?
     WHERE param_value_id = ?::uuid AND status IN ('PENDING', 'DRAFT')""",
    $checker, reason, paramValueId) == 1

proc pendingValues*(db: DbConn): seq[(string, string)] =
  ## (param_value_id, key) yang menunggu checker.
  for row in db.getAllRows(sql"""
    SELECT param_value_id::text, key FROM platform.param_value
     WHERE status IN ('DRAFT','PENDING') ORDER BY recorded_at"""):
    result.add (row[0], row[1])

proc missingActiveKeys*(db: DbConn, keys: openArray[string], scopeType: ParamScopeType,
                        scopeId, asOf: string): seq[string] =
  ## Startup check (spec §10.4): key yang **tidak** punya nilai aktif untuk scope yang wajib.
  ## `GLOBAL` selalu dianggap tersedia; key lain butuh nilai pada scope-nya sendiri atau GLOBAL.
  for key in keys:
    let candidates = candidatesOf(db, key, asOf)
    var found = false
    for c in candidates:
      if c.scopeType == pstGlobal:
        found = true
      elif c.scopeType == scopeType and (scopeId.len == 0 or c.scopeId == scopeId):
        found = true
    if not found:
      result.add key

type
  ChangeOutcome* = object
    paramValueId*: string
    eventId*: Id
    auditHash*: string

proc submitChange*(db: DbConn, ctx: AuditContext, clock: Clock, key, scopeType, scopeId: string,
                   value: JsonNode, effectiveFrom, effectiveTo, reason: string): ChangeOutcome =
  ## Satu transaksi (pemanggil membungkus `withTx`): nilai PENDING + audit + event outbox.
  ## Nilai belum terlihat aplikasi sampai disetujui (`approveChange`).
  let pvId = $newId(clock)
  let submit = submitValue(db, pvId, key, scopeType, scopeId, value, effectiveFrom, effectiveTo,
    ctx.userId, reason)
  result.paramValueId = submit.paramValueId
  result.auditHash = appendAudit(db, newAuditEntry(ctx, "param.submit", "param_value", pvId,
    clock, businessDate = effectiveFrom, after = %*{
      "key": key, "scope_type": scopeType, "scope_id": scopeId, "value": value,
      "effective_from": effectiveFrom, "effective_to": effectiveTo, "status": $pvPending}))
  result.eventId = newId(clock)
  discard appendEvent(db, newOutboxEvent(result.eventId, "param.changed", "param_value", pvId,
    "param.change:" & pvId & ":submitted", %*{
      "key": key, "scope_type": scopeType, "scope_id": scopeId, "status": $pvPending,
      "effective_from": effectiveFrom, "value": value}))

proc approveChange*(db: DbConn, ctx: AuditContext, clock: Clock,
                    paramValueId: string): ChangeOutcome =
  ## Aktivasi oleh checker: supersede nilai lama + audit + event + `NOTIFY` invalidasi cache.
  ## Raise `DbError` bila bentrok periode (EXCLUDE) atau `checker = maker`.
  let found = db.singleRow(sql"""
    SELECT key, scope_type, coalesce(scope_id, ''), value::text,
           to_char(effective_from, 'YYYY-MM-DD') FROM platform.param_value
     WHERE param_value_id = ?::uuid""", paramValueId)
  if found.isNone:
    raise newException(ValueError, "param_value_id tidak ditemukan: " & paramValueId)
  let row = found.get()
  # Snapshot ACTIVE sebelum perubahan (untuk audit `before`).
  var beforeValue = newJNull()
  let before = db.singleRow(sql"""
    SELECT value::text FROM platform.param_value
     WHERE key = ? AND scope_type = ? AND coalesce(scope_id, '') = ?
       AND status IN ('ACTIVE', 'SUPERSEDED') AND effective_from <= ?::date
       AND (effective_to IS NULL OR effective_to > ?::date)
      ORDER BY effective_from DESC LIMIT 1""", row[0], row[1], row[2], row[4], row[4])
  if before.isSome:
    beforeValue = parseJson(before.get()[0])

  if not approveValue(db, paramValueId, ctx.userId):
    raise newException(ValueError, "nilai " & paramValueId & " tidak berstatus PENDING")

  result.paramValueId = paramValueId
  result.auditHash = appendAudit(db, newAuditEntry(ctx, "param.approve", "param_value",
    paramValueId, clock, businessDate = row[4], before = beforeValue,
    after = parseJson(row[3])))
  result.eventId = newId(clock)
  discard appendEvent(db, newOutboxEvent(result.eventId, "param.changed", "param_value",
    paramValueId, "param.change:" & paramValueId & ":approved", %*{
      "key": row[0], "scope_type": row[1], "scope_id": row[2], "status": $pvActive,
      "effective_from": row[4], "value": parseJson(row[3])}))
  notifyChange(db, row[0])
