## Handler laporan `ledger` (T-075): trial balance.
##
## Angka dihitung dari `journal_line` (sumber kebenaran), bukan dari cache `balance_snapshot`.
## Izin memakai `ledger.journal.read`: siapa pun yang boleh membaca jurnal boleh membaca agregatnya.

import std/[json, options, strutils]

import mummy
import db_connector/db_postgres

import kernel/[ids, money, result]
import ledger/domain/report
import ledger/infrastructure/report_repo

import ./access
import ./context
import ./db_bridge
import ./handlers_journals
import ./http_util
import ./problem

proc trialBalanceJson(tb: TrialBalance): JsonNode =
  var lines = newJArray()
  for l in tb.lines:
    lines.add %*{
      "accountCode": l.accountCode,
      "accountName": l.accountName,
      "accountType": $l.accountType,
      "debit": l.debit.toDecimalString,
      "credit": l.credit.toDecimalString,
    }
  %*{
    "periodId": $tb.periodId,
    "startsOn": tb.startsOn,
    "endsOn": tb.endsOn,
    "totalDebit": tb.totalDebit.toDecimalString,
    "totalCredit": tb.totalCredit.toDecimalString,
    "lines": lines,
  }

proc handleTrialBalance*(app: AppContext, req: Request) {.gcsafe.} =
  ## `GET /api/v1/ledger/trial-balance?periodId=...` — agregat debit/kredit per akun.
  let principalOpt = requirePrincipal(app, req)
  if principalOpt.isNone:
    return
  let principal = principalOpt.get()
  if not requirePermission(app, req, principal, permissionJournalRead):
    return

  let periodId = parseId(queryValue(req, "periodId").strip)
  if periodId.isErr:
    req.respondProblem(pkBadRequest, "Bad Request", "periodId wajib berupa uuid")
    return

  var status = 0
  var problem = ""
  var payload = newJObject()
  try:
    withDbConn(app.pool, proc(db: DbConn) {.gcsafe.} =
      dbCalls:
        if not authorizedAtBranch(db, principal, "", permissionJournalRead):
          status = 403
          return
        let tb = trialBalance(db, periodId.value())
        if tb.isNone:
          status = 404
          problem = "periode tidak ditemukan"
          return
        payload = trialBalanceJson(tb.get())
        status = 200)
  except ValueError:
    # Data ledger tidak konsisten (mis. account_type tak dikenal): bukan 404, dan jangan
    # membocorkan nilai DB ke respons.
    status = 500
    problem = "trial balance tidak dapat dihitung karena data tidak konsisten"
  except DbError:
    status = 500
    problem = "trial balance gagal dihitung"

  case status
  of 200: req.respondJson(200, payload)
  of 403: req.respondProblem(newProblem(pkForbidden, "Forbidden",
    "aksi tingkat institusi ledger.journal.read hanya boleh dengan grant tanpa batas cabang",
    traceId = traceIdFrom(req),
    params = @[("reason", "branch_not_allowed"),
               ("permission", permissionJournalRead)]))
  of 404: req.respondProblem(pkNotFound, "Not Found", problem)
  else: req.respondProblem(pkInternal, "Internal Server Error", problem)
