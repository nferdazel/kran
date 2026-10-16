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

proc pgArrayItems*(raw: string): seq[string] =
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

proc committedFromDates*(db: DbConn, key, sinceIso: string): seq[string] =
  ## Tanggal mulai efektif yang **sudah disetujui** dan belum lewat untuk satu key.
  ##
  ## `ACTIVE` **dan** `SUPERSEDED` ikut disertakan: baris yang sudah dipangkas tetap berlaku sampai
  ## `effective_to`-nya (pola riwayat effective-dated, sama seperti `activeValueSql`), jadi tanggal
  ## mulainya tetap titik perubahan nilai yang harus dinilai. Tanpa itu, baris ber-tanggal depan yang
  ## kemudian dipangkas oleh baris yang lebih akhir akan hilang dari himpunan tanggal.
  for row in db.getAllRows(sql"""
    SELECT DISTINCT to_char(effective_from, 'YYYY-MM-DD')
      FROM platform.param_value
     WHERE key = ? AND status IN ('ACTIVE', 'SUPERSEDED') AND effective_from >= ?::date
     ORDER BY 1""", key, sinceIso):
    result.add row[0]

proc activeValueJson*(db: DbConn, key, asOf: string, lookup: ScopeValueLookup): JsonNode =
  ## Nilai aktif paling spesifik untuk `key` pada `asOf`. Raise `ValueError` bila tidak ada —
  ## satu-satunya tempat aturan "tanpa fallback diam-diam" (spec §10.6) diterapkan.
  let picked = resolveCandidate(candidatesOf(db, key, asOf), lookup)
  if picked.isNone:
    raise newException(ValueError,
      "parameter " & key & " tidak punya nilai aktif pada " & asOf)
  picked.get().value

proc activeParamInt*(db: DbConn, key, asOf: string, lookup: ScopeValueLookup): int =
  let value = db.activeValueJson(key, asOf, lookup)
  if value.kind != JInt:
    raise newException(ValueError, "parameter " & key & " bukan integer: " & $value)
  int(value.getInt)

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

proc statusOf*(db: DbConn, paramValueId: string): Option[ParamStatus] =
  ## Status nilai parameter, `none` bila id tidak ada. Dipakai handler persetujuan: membedakan
  ## "tidak ada" (404) dari "bukan PENDING" (409) tanpa menebak dari pesan error DB.
  let found = singleRow(db,
    sql"SELECT status FROM platform.param_value WHERE param_value_id = ?::uuid", paramValueId)
  if found.isNone:
    return none(ParamStatus)
  some(parseStatus(found.get()[0]))

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

proc supersedePreviousValues*(db: DbConn, paramValueId: string): int =
  ## Memangkas nilai ACTIVE sebelumnya pada (key, scope) yang sama (`SUPERSEDED`, `effective_to` =
  ## `effective_from` nilai baru) — pola supersede, bukan tumpang tindih. Dipisah dari
  ## `approveValue` supaya langkah aktivasi bisa diuji sendiri (lihat `activatePending`).
  db.execAffectedRows(sql"""
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

proc activatePending*(db: DbConn, paramValueId: string, checker: Id): bool =
  ## PENDING → ACTIVE; `true` hanya bila statusnya benar-benar berpindah.
  ##
  ## Klausa `AND status = 'PENDING'` adalah penjaga **optimistik**: dua checker yang menyetujui
  ## nilai yang sama hampir bersamaan tidak bisa dua-duanya berhasil. Pemeriksaan status sebelum
  ## ini (`approveValue`) hanya melihat snapshot READ COMMITTED; tanpa penjaga di UPDATE, yang
  ## kalah tetap menulis ACTIVE + audit + event kedua. Yang kalah kini melihat 0 baris, lalu
  ## `approveChange` melempar `ValueError` dan pemanggil membatalkan transaksinya (409
  ## `not_pending`).
  db.execAffectedRows(sql"""
    UPDATE platform.param_value SET status = 'ACTIVE', checker = ?::uuid
     WHERE param_value_id = ?::uuid AND status = 'PENDING'""", $checker, paramValueId) == 1

proc approveValue*(db: DbConn, paramValueId: string, checker: Id): bool =
  ## Menyetujui nilai (checker) → ACTIVE. Mengembalikan `false` bila nilainya tidak PENDING.
  ## Raise `DbError` bila periode baru menabrak ACTIVE lain (EXCLUDE) atau `checker = maker`.
  if db.getValue(sql"SELECT status FROM platform.param_value WHERE param_value_id = ?::uuid",
      paramValueId) != "PENDING":
    return false
  discard supersedePreviousValues(db, paramValueId)
  activatePending(db, paramValueId, checker)

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

type
  ParamValueRow* = object
    ## Satu baris `param_value` + metadata definisinya — bahan daftar UI Parameter Admin
    ## (spec §10.7): nilai aktif maupun yang menunggu persetujuan.
    paramValueId*: string
    key*: string
    scopeType*: string
    scopeId*: string
    status*: ParamStatus
    value*: JsonNode
    effectiveFrom*: string
    effectiveTo*: string
    maker*: string
    checker*: string
    reason*: string
    requiresApproval*: bool

proc paramValueRows*(db: DbConn, status = "", limit = 200): seq[ParamValueRow] =
  ## Daftar nilai parameter (semua scope) untuk UI. `status` kosong = semua status; disaring
  ## memakai nama status kanonik (`ACTIVE`, `PENDING`, …). Batas jumlah baris wajib.
  for row in db.getAllRows(sql"""
    SELECT v.param_value_id::text, v.key, v.scope_type, coalesce(v.scope_id::text, ''),
           v.status, v.value::text,
           to_char(v.effective_from, 'YYYY-MM-DD'),
           coalesce(to_char(v.effective_to, 'YYYY-MM-DD'), ''),
           coalesce(v.maker::text, ''), coalesce(v.checker::text, ''), coalesce(v.reason, ''),
           d.requires_approval
      FROM platform.param_value v
      JOIN platform.param_definition d ON d.key = v.key
     WHERE (?::text = '' OR v.status = ?)
     ORDER BY v.key, v.recorded_at DESC
     LIMIT ?::int""", status, status, $limit):
    result.add ParamValueRow(
      paramValueId: row[0],
      key: row[1],
      scopeType: row[2],
      scopeId: row[3],
      status: parseStatus(row[4]),
      value: parseJson(row[5]),
      effectiveFrom: row[6],
      effectiveTo: row[7],
      maker: row[8],
      checker: row[9],
      reason: row[10],
      requiresApproval: row[11] == "t")

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

  PendingRow* = object
    ## Nilai yang akan diaktifkan: key/scope/nilai/tanggal efektif. Dipakai `approveChange`
    ## (snapshot audit) dan pemeriksaan lintas-parameter sebelum aktivasi.
    key*: string
    scopeType*: string
    scopeId*: string
    value*: JsonNode
    effectiveFrom*: string
    effectiveTo*: string

proc pendingValueOf*(db: DbConn, paramValueId: string): Option[PendingRow] =
  ## `none` bila id tidak ada (pemanggil memetakannya ke 404).
  let found = db.singleRow(sql"""
    SELECT key, scope_type, coalesce(scope_id, ''), value::text,
           to_char(effective_from, 'YYYY-MM-DD'),
           coalesce(to_char(effective_to, 'YYYY-MM-DD'), '')
      FROM platform.param_value
     WHERE param_value_id = ?::uuid""", paramValueId)
  if found.isNone:
    return none(PendingRow)
  let row = found.get()
  some(PendingRow(key: row[0], scopeType: row[1], scopeId: row[2],
    value: parseJson(row[3]), effectiveFrom: row[4], effectiveTo: row[5]))

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
  let found = pendingValueOf(db, paramValueId)
  if found.isNone:
    raise newException(ValueError, "param_value_id tidak ditemukan: " & paramValueId)
  let pending = found.get()
  # Snapshot ACTIVE sebelum perubahan (untuk audit `before`).
  var beforeValue = newJNull()
  let before = db.singleRow(sql"""
    SELECT value::text FROM platform.param_value
     WHERE key = ? AND scope_type = ? AND coalesce(scope_id, '') = ?
       AND status IN ('ACTIVE', 'SUPERSEDED') AND effective_from <= ?::date
       AND (effective_to IS NULL OR effective_to > ?::date)
      ORDER BY effective_from DESC LIMIT 1""",
    pending.key, pending.scopeType, pending.scopeId, pending.effectiveFrom, pending.effectiveFrom)
  if before.isSome:
    beforeValue = parseJson(before.get()[0])

  if not approveValue(db, paramValueId, ctx.userId):
    raise newException(ValueError, "nilai " & paramValueId & " tidak berstatus PENDING")

  result.paramValueId = paramValueId
  result.auditHash = appendAudit(db, newAuditEntry(ctx, "param.approve", "param_value",
    paramValueId, clock, businessDate = pending.effectiveFrom, before = beforeValue,
    after = pending.value))
  result.eventId = newId(clock)
  discard appendEvent(db, newOutboxEvent(result.eventId, "param.changed", "param_value",
    paramValueId, "param.change:" & paramValueId & ":approved", %*{
      "key": pending.key, "scope_type": pending.scopeType, "scope_id": pending.scopeId,
      "status": $pvActive, "effective_from": pending.effectiveFrom, "value": pending.value}))
  notifyChange(db, pending.key)
