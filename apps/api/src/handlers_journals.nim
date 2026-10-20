## Handler REST jurnal `ledger` (T-073, spec §9.1(3), §9.3).
##
## Jurnal **tidak** dibuat lewat HTTP: pembuatan berasal dari posting rule/event (T-074). Yang
## tersedia hanya baca dan **jurnal pembalik** — tidak ada edit/hapus, dan DB menolak keduanya.
##
## **HUMAN-REVIEW-REQUIRED**: jurnal double-entry (AGENTS.md §8).

import std/[json, options, strutils]

import mummy
import db_connector/db_postgres

import "platform-lib/db/pool"

import kernel/[ids, money, result]
import platform/domain/[audit, event, scope]
import platform/infrastructure/[audit_repo, auth_service, outbox_repo]
import ledger/domain/[journal, period]
import ledger/infrastructure/journal_repo

import ./access
import ./context
import ./db_bridge
import ./http_util
import ./problem

const
  permissionJournalRead* = "ledger.journal.read"
  permissionJournalReverse* = "ledger.journal.reverse"

proc respondInstitutionOnly(req: Request, permission: string) =
  req.respondProblem(newProblem(pkForbidden, "Forbidden",
    "aksi tingkat institusi " & permission & " hanya boleh dengan grant tanpa batas cabang",
    traceId = traceIdFrom(req),
    params = @[("reason", "branch_not_allowed"), ("permission", permission)]))

proc lineJson(l: JournalLine): JsonNode =
  %*{
    "lineNo": l.lineNo,
    "glAccount": l.glAccount,
    "branchId": $l.branchId,
    "debit": l.debit.toDecimalString,
    "credit": l.credit.toDecimalString,
  }

proc headerJson(j: Journal): JsonNode =
  %*{
    "journalId": $j.journalId,
    "businessDate": j.businessDate,
    "valueDate": j.valueDate,
    "sourceEvent": j.sourceEvent,
    "sourceRef": $j.sourceRef,
    "idempotencyKey": j.idempotencyKey,
    "reversalOf": if j.reversalOf.len == 0: newJNull() else: %j.reversalOf,
    "recordedAt": j.recordedAt,
  }

proc journalJson(j: Journal): JsonNode =
  result = headerJson(j)
  var lines = newJArray()
  for l in j.lines:
    lines.add lineJson(l)
  result["lines"] = lines
  result["totalDebit"] = %j.lines.totalDebit.toDecimalString
  result["totalCredit"] = %j.lines.totalCredit.toDecimalString

proc handleListJournals*(app: AppContext, req: Request) {.gcsafe.} =
  ## `GET /api/v1/ledger/journals` — daftar header, terbaru lebih dulu.
  let principalOpt = requirePrincipal(app, req)
  if principalOpt.isNone:
    return
  let principal = principalOpt.get()
  if not requirePermission(app, req, principal, permissionJournalRead):
    return

  let businessDate = queryValue(req, "businessDate").strip
  if businessDate.len > 0:
    try:
      discard parseIsoDate(businessDate, "businessDate")
    except ValueError as e:
      req.respondProblem(pkBadRequest, "Bad Request", e.msg)
      return
  let sourceEvent = queryValue(req, "sourceEvent").strip

  var status = 0
  var items = newJArray()
  try:
    withDbConn(app.pool, proc(db: DbConn) {.gcsafe.} =
      dbCalls:
        if not authorizedAtBranch(db, principal, "", permissionJournalRead):
          status = 403
          return
        for j in journals(db, businessDate, sourceEvent):
          items.add headerJson(j)
        status = 200)
  except DbError:
    status = 500

  case status
  of 200: req.respondJson(200, %*{"items": items})
  of 403: req.respondInstitutionOnly(permissionJournalRead)
  else: req.respondProblem(pkInternal, "Internal Server Error", "daftar jurnal gagal dibaca")

proc handleGetJournal*(app: AppContext, req: Request) {.gcsafe.} =
  ## `GET /api/v1/ledger/journals/{journalId}` — detail + baris.
  let principalOpt = requirePrincipal(app, req)
  if principalOpt.isNone:
    return
  let principal = principalOpt.get()
  if not requirePermission(app, req, principal, permissionJournalRead):
    return

  let journalId = parseId(pathParam(req, "journalId"))
  if journalId.isErr:
    req.respondProblem(pkNotFound, "Not Found", "jurnal tidak ditemukan")
    return

  var status = 0
  var payload = newJObject()
  try:
    withDbConn(app.pool, proc(db: DbConn) {.gcsafe.} =
      dbCalls:
        if not authorizedAtBranch(db, principal, "", permissionJournalRead):
          status = 403
          return
        let j = journalById(db, journalId.value())
        if j.isNone:
          status = 404
          return
        payload = journalJson(j.get())
        status = 200)
  except DbError:
    status = 500

  case status
  of 200: req.respondJson(200, payload)
  of 403: req.respondInstitutionOnly(permissionJournalRead)
  of 404: req.respondProblem(pkNotFound, "Not Found", "jurnal tidak ditemukan")
  else: req.respondProblem(pkInternal, "Internal Server Error", "jurnal gagal dibaca")

proc handleReverseJournal*(app: AppContext, req: Request) {.gcsafe.} =
  ## `POST /api/v1/ledger/journals/{journalId}/reversal` — jurnal pembalik, idempoten.
  let principalOpt = requirePrincipal(app, req)
  if principalOpt.isNone:
    return
  let principal = principalOpt.get()
  if not requirePermission(app, req, principal, permissionJournalReverse):
    return

  var idempotencyKey = ""
  try:
    idempotencyKey = validateIdempotencyKey(req.headers["Idempotency-Key"])
  except ValueError as e:
    req.respondProblem(pkBadRequest, "Bad Request", e.msg)
    return

  let body = parseJsonBody(req)
  if body.isNone or body.get().kind != JObject:
    req.respondProblem(pkBadRequest, "Bad Request", "badan permintaan harus objek JSON")
    return
  var reason = ""
  try:
    reason = validateReversalReason(body.get().jsonField("reason"))
  except ValueError as e:
    req.respondProblem(pkBadRequest, "Bad Request", e.msg)
    return

  let journalId = parseId(pathParam(req, "journalId"))
  if journalId.isErr:
    req.respondProblem(pkNotFound, "Not Found", "jurnal tidak ditemukan")
    return

  var status = 0
  var problem = ""
  var payload = newJObject()
  try:
    withDbTx(app.pool, proc(db: DbConn) {.gcsafe.} =
      dbCalls:
        if not authorizedAtBranch(db, principal, "", permissionJournalReverse):
          status = 403
          return

        # Permintaan ulang dengan kunci yang sama = idempoten (200), bukan jurnal kedua.
        let existing = journalByIdempotencyKey(db, idempotencyKey)
        if existing.isSome:
          if existing.get().reversalOf == $journalId.value():
            payload = journalJson(existing.get())
            status = 200
            return
          status = 409
          problem = "Idempotency-Key sudah dipakai untuk jurnal lain"
          raise newException(ValueError, problem)

        let original = journalById(db, journalId.value())
        if original.isNone:
          status = 404
          problem = "jurnal tidak ditemukan"
          raise newException(ValueError, problem)
        if original.get().reversalOf.len > 0:
          status = 409
          problem = "jurnal pembalik tidak bisa dibalik lagi"
          raise newException(ValueError, problem)
        if reversalExistsFor(db, journalId.value()):
          status = 409
          problem = "jurnal sudah dibalik"
          raise newException(ValueError, problem)
        if not periodOpenFor(db, original.get().businessDate):
          status = 409
          problem = "periode tanggal bisnis jurnal sudah ditutup"
          raise newException(ValueError, problem)

        let reversal = Journal(
          journalId: newId(app.clock),
          businessDate: original.get().businessDate,
          valueDate: original.get().valueDate,
          sourceEvent: "reversal",
          sourceRef: journalId.value(),
          idempotencyKey: idempotencyKey,
          reversalOf: $journalId.value())
        let recordedAt = insertJournal(db, reversal, parseId(principal.user.userId).value())
        let lines = reversalLinesOf(original.get().lines)
        for line in lines:
          insertJournalLine(db, reversal.journalId, line)

        let ctx = auditContextFor(principal, req, app.clock, reason)
        discard appendAudit(db, newAuditEntry(ctx, "ledger.journal.reverse", "journal",
          $reversal.journalId, app.clock,
          businessDate = businessDateFor(db, institutionScope(), original.get().businessDate),
          after = %*{"journalId": $reversal.journalId,
                     "reversalOf": $journalId.value(),
                     "sourceEvent": "reversal"}))
        discard appendEvent(db, newOutboxEvent(newId(app.clock), "journal.posted", "journal",
          $reversal.journalId, "journal.posted:" & $reversal.journalId,
          %*{"journalId": $reversal.journalId,
             "businessDate": original.get().businessDate,
             "reversalOf": $journalId.value(),
             "totalDebit": lines.totalDebit.toDecimalString}))

        var done = reversal
        done.lines = lines
        done.recordedAt = recordedAt
        payload = journalJson(done)
        status = 201)
  except ValueError as e:
    if status == 0:
      status = 400
    problem = e.msg
  except DbError as e:
    if "journal_reversal_uq" in e.msg:
      # Dijamin indeks unik parsial: hanya satu pembalik per jurnal asal. Bila yang kalah adalah
      # retry dengan kunci yang sama, kontraknya tetap 200 (baca ulang seperti cabang idempotensi).
      var existing: Option[Journal]
      {.cast(gcsafe).}:
        existing = app.pool.withConn(proc(d: DbConn): Option[Journal] {.gcsafe.} =
          journalByIdempotencyKey(d, idempotencyKey))
      if existing.isSome and existing.get().reversalOf == $journalId.value():
        status = 200
        payload = journalJson(existing.get())
      else:
        status = 409
        problem = "jurnal sudah dibalik"
    elif "journal_idempotency_uq" in e.msg:
      # Balapan kunci yang sama: transaksi ini kalah, tetapi yang menang sudah COMMIT. Baca ulang
      # di koneksi baru; bila memang jurnal pembalik untuk asal yang sama → 200 (kontrak idempoten),
      # bukan 409.
      var existing: Option[Journal]
      {.cast(gcsafe).}:
        existing = app.pool.withConn(proc(d: DbConn): Option[Journal] {.gcsafe.} =
          journalByIdempotencyKey(d, idempotencyKey))
      if existing.isSome and existing.get().reversalOf == $journalId.value():
        status = 200
        payload = journalJson(existing.get())
      else:
        status = 409
        problem = "Idempotency-Key sudah dipakai untuk jurnal lain"
    elif "tidak ada periode OPEN" in e.msg or "sudah ditutup" in e.msg:
      status = 409
      problem = "periode tanggal bisnis jurnal sudah ditutup"
    elif "tidak postable atau tidak aktif" in e.msg:
      status = 409
      problem = "akun jurnal tidak postable atau tidak aktif"
    else:
      status = 500
      problem = "jurnal pembalik gagal disimpan"

  case status
  of 200, 201: req.respondJson(status, payload)
  of 400: req.respondProblem(pkBadRequest, "Bad Request", problem)
  of 403: req.respondInstitutionOnly(permissionJournalReverse)
  of 404: req.respondProblem(pkNotFound, "Not Found", problem)
  of 409: req.respondProblem(pkConflict, "Conflict", problem)
  else: req.respondProblem(pkInternal, "Internal Server Error", problem)
