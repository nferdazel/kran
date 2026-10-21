## Handler laporan `ledger` (T-075): trial balance.
##
## Angka dihitung dari `journal_line` (sumber kebenaran), bukan dari cache `balance_snapshot`.
## Izin memakai `ledger.journal.read`: siapa pun yang boleh membaca jurnal boleh membaca agregatnya.

import std/[json, options, strutils, times]

import mummy
import db_connector/db_postgres

import kernel/[clock, ids, money, result]
import ledger/domain/[period, report]
import ledger/infrastructure/[ledger_repo, report_repo]

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

proc isoUtc(clock: Clock): string =
  ## `computedAt` wajib ISO-8601 UTC (D-096); bentuknya sama dengan kolom waktu lain di API.
  format(clock.now().utc, "yyyy-MM-dd'T'HH:mm:ss'Z'")

proc balancesJson(periodId: Id, p: Period, source: BalanceSource,
                  lines: seq[BalanceLine], nowIso: string): JsonNode =
  var arr = newJArray()
  for l in lines:
    arr.add %*{
      "accountCode": l.accountCode,
      "accountName": l.accountName,
      "accountType": $l.accountType,
      "openingDebit": l.openingDebit.toDecimalString,
      "openingCredit": l.openingCredit.toDecimalString,
      "periodDebit": l.periodDebit.toDecimalString,
      "periodCredit": l.periodCredit.toDecimalString,
      "closingDebit": l.closingDebit.toDecimalString,
      "closingCredit": l.closingCredit.toDecimalString,
    }
  %*{
    "periodId": $periodId,
    "startsOn": p.startsOn,
    "endsOn": p.endsOn,
    "source": $source,
    "computedAt": nowIso,
    "lines": arr,
  }

proc handleLedgerBalances*(app: AppContext, req: Request) {.gcsafe.} =
  ## `GET /api/v1/ledger/balances?periodId=` — saldo GL opening/period/closing (T-082, D-096).
  ## Angka selalu dihitung dari `journal_line` (sumber kebenaran). `source=snapshot` hanya bila
  ## periode CLOSED **dan** cache `balance_snapshot` pada `endsOn` terekonsiliasi dengan jurnal.
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
        let period = periodById(db, periodId.value())
        if period.isNone:
          status = 404
          problem = "periode tidak ditemukan"
          return
        let p = period.get()
        let lines = balancesFromLedger(db, p.startsOn, p.endsOn)
        var source = bsLedger
        # Snapshot **hanya sah untuk periode CLOSED** dan hanya bila terekonsiliasi (D-096).
        if p.status == psClosed and
            snapshotMatches(lines, snapshotBalances(db, p.endsOn)):
          source = bsSnapshot
        payload = balancesJson(periodId.value(), p, source, lines, isoUtc(app.clock))
        status = 200)
  except ValueError:
    status = 500
    problem = "laporan saldo tidak dapat dihitung karena data tidak konsisten"
  except DbError:
    status = 500
    problem = "laporan saldo gagal dihitung"

  case status
  of 200: req.respondJson(200, payload)
  of 403: req.respondProblem(newProblem(pkForbidden, "Forbidden",
    "aksi tingkat institusi ledger.journal.read hanya boleh dengan grant tanpa batas cabang",
    traceId = traceIdFrom(req),
    params = @[("reason", "branch_not_allowed"),
               ("permission", permissionJournalRead)]))
  of 404: req.respondProblem(pkNotFound, "Not Found", problem)
  else: req.respondProblem(pkInternal, "Internal Server Error", problem)
