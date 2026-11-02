## Handler laporan pinjaman (T-171): tunggakan/aging, penyisihan, rekonsiliasi.
##
## Tiga laporan, tiga tanggal acuan — lihat `lending/domain/report.nim` untuk alasannya. Semuanya
## **baca-saja**: tidak ada jurnal, audit, atau outbox yang ditulis dari sini.
##
## Izin `lending.loan.read` pada tingkat **institusi** (pola laporan `ledger`, `handlers_reports`):
## laporan agregat lintas cabang bukan hak pemegang izin satu cabang. Menyaring per baris seperti
## daftar pinjaman akan membuat angka total di laporan tidak pernah cocok dengan GL.

import std/[json, options, strutils]

import mummy
import db_connector/db_postgres

import kernel/[businessdate, ids, money, paramkey, result]
import kernel/generated/paramkeys
import platform/domain/scope
import platform/infrastructure/param_repo
import lending/domain/[collectibility, report]
import lending/infrastructure/report_repo
import ledger/domain/report as ledgerReport
import ledger/infrastructure/report_repo as ledgerReportRepo

import ./access
import ./context
import ./db_bridge
import ./handlers_lending
import ./http_util
import ./problem

const
  ## Awal rentang laporan GL: sebelum ada jurnal. Bukan tanggal bisnis institusi — laporan
  ## rekonsiliasi membandingkan **seluruh** saldo akun dengan subledger.
  glHistoryStart = "1970-01-01"
  glLoanReceivable = "110"
  glLoanAllowance = "111"

proc moneyOfText(text: string): Money =
  ## Teks desimal dari DB/repo. Rusak = data tidak konsisten (500), bukan 400: pemanggil tidak
  ## mengirimnya.
  let parsed = moneyFromString(text)
  if not parsed.isOk:
    raise newException(ValueError, "nominal laporan bukan desimal sah: " & text)
  parsed.val

proc gradeOfText(raw: string): Collectibility =
  let parsed = parseCollectibility(raw)
  if parsed.isNone:
    raise newException(ValueError, "golongan kolektibilitas tidak dikenal: " & raw)
  parsed.get()

proc dpdBoundsFor(db: DbConn; asOf: string): seq[int] =
  ## Ambang **pada tanggal laporan**. Laporan tanggal lampau memakai kebijakan yang berlaku saat
  ## itu; memakai ambang hari ini akan mengubah laporan yang sudah dipublikasikan.
  let value = activeValueJson(db, keyString(P_lending_collectibility_dpd_bounds), asOf,
    lookupFor(institutionScope()))
  let parsed = parseDpdBounds(value)
  if not parsed.isOk:
    raise newException(ValueError, parsed.error.details)
  parsed.val

proc requestedAsOf(app: AppContext; req: Request): Option[string] =
  ## `none` = `asOf` tidak sah (pemanggil menjawab 400). Kosong = tanggal buku hari ini.
  let raw = queryValue(req, "asOf").strip
  if raw.len == 0:
    return some(businessDateIso(app.clock))
  let parsed = parseBusinessDate(raw)
  if not parsed.isOk:
    return none(string)
  some(raw)

proc glAmount(db: DbConn; asOf, accountCode: string; creditNormal: bool): Money =
  ## Saldo akun per `asOf` dari **jurnal** (bukan cache `balance_snapshot`): pembanding subledger
  ## harus sumber yang sama dengan yang dipakai laporan keuangan. Akun yang belum pernah bergerak
  ## = nol, bukan galat.
  for line in ledgerReportRepo.balancesFromLedger(db, glHistoryStart, asOf):
    if line.accountCode != accountCode:
      continue
    let debit = ledgerReport.closingDebit(line)
    let credit = ledgerReport.closingCredit(line)
    return (if creditNormal: credit - debit else: debit - credit)
  zero()

proc itemJson(item: ArrearsItem): JsonNode =
  %*{
    "loanId": $item.loanId,
    "partyId": $item.partyId,
    "branchId": $item.branchId,
    "dpd": item.dpd,
    "grade": $item.grade,
    "principal": item.principal.toDecimalString,
    "interest": item.interest.toDecimalString,
    "penalty": item.penalty.toDecimalString,
    "total": item.lineTotal.toDecimalString,
  }

proc agingJson(line: GradeAging): JsonNode =
  %*{
    "grade": $line.grade,
    "loans": line.loans,
    "principal": line.principal.toDecimalString,
    "interest": line.interest.toDecimalString,
    "penalty": line.penalty.toDecimalString,
    "total": line.total.toDecimalString,
  }

proc handleArrearsReport*(app: AppContext; req: Request) {.gcsafe.} =
  ## `GET /api/v1/lending/reports/arrears?asOf=` — tunggakan per pinjaman + aging per golongan.
  let principalOpt = requirePrincipal(app, req)
  if principalOpt.isNone:
    return
  let principal = principalOpt.get()
  if not requirePermission(app, req, principal, permissionLendingRead):
    return
  let asOfOpt = requestedAsOf(app, req)
  if asOfOpt.isNone:
    req.respondProblem(pkBadRequest, "Bad Request", "asOf harus tanggal YYYY-MM-DD")
    return
  let asOf = asOfOpt.get()

  var payload = newJNull()
  var forbidden = false
  try:
    withDbConn(app.pool, proc(db: DbConn) {.gcsafe.} =
      dbCalls:
        if not authorizedAtBranch(db, principal, "", permissionLendingRead):
          forbidden = true
          return
        let bounds = dpdBoundsFor(db, asOf)
        var report = ArrearsReport(asOf: asOf)
        for row in arrearsRows(db, asOf):
          let dpd = daysPastDue(row.dueOn, asOf)
          if not dpd.isOk:
            raise newException(ValueError, dpd.error.details)
          # Golongan tercatat pada tanggal itu menang; DPD dipakai hanya bila task regrading belum
          # pernah menilai hari itu, dan itu ditandai di respons (`graded` per baris tidak dibuat:
          # fallback-nya satu aturan yang sama, ambang parameter).
          let grade = if row.grade.len > 0: gradeOfText(row.grade)
                      else: gradeOf(dpd.val, bounds).val
          report.items.add ArrearsItem(
            loanId: row.loanId,
            partyId: row.partyId,
            branchId: row.branchId,
            dpd: dpd.val,
            grade: grade,
            principal: moneyOfText(row.principal),
            interest: moneyOfText(row.interest),
            penalty: moneyOfText(row.penalty),
          )
        report.items = byDpd(report.items)
        report.byGrade = groupByGrade(report.items)

        let totals = report.combined
        var items = newJArray()
        for item in report.items:
          items.add itemJson(item)
        var aging = newJArray()
        for line in report.byGrade:
          aging.add agingJson(line)
        payload = %*{
          "asOf": report.asOf,
          "items": items,
          "totals": %*{
            "loans": report.items.len,
            "principal": totals.principal.toDecimalString,
            "interest": totals.interest.toDecimalString,
            "penalty": totals.penalty.toDecimalString,
            "total": totals.total.toDecimalString,
          },
          "aging": aging,
        })
  except ValueError:
    req.respondProblem(pkInternal, "Internal Server Error",
      "laporan tunggakan gagal dihitung karena data tidak konsisten")
    return
  except DbError:
    req.respondProblem(pkInternal, "Internal Server Error", "laporan tunggakan gagal dihitung")
    return

  if forbidden:
    req.respondProblem(pkForbidden, "Forbidden",
      "izin " & permissionLendingRead & " tidak dipegang pada tingkat institusi")
    return
  req.respondJson(200, payload)

proc handleAllowanceReport*(app: AppContext; req: Request) {.gcsafe.} =
  ## `GET /api/v1/lending/reports/allowance?asOf=` — penyisihan PPAP tercatat per golongan.
  let principalOpt = requirePrincipal(app, req)
  if principalOpt.isNone:
    return
  let principal = principalOpt.get()
  if not requirePermission(app, req, principal, permissionLendingRead):
    return
  let asOfOpt = requestedAsOf(app, req)
  if asOfOpt.isNone:
    req.respondProblem(pkBadRequest, "Bad Request", "asOf harus tanggal YYYY-MM-DD")
    return
  let asOf = asOfOpt.get()

  var payload = newJNull()
  var forbidden = false
  try:
    withDbConn(app.pool, proc(db: DbConn) {.gcsafe.} =
      dbCalls:
        if not authorizedAtBranch(db, principal, "", permissionLendingRead):
          forbidden = true
          return
        var report = AllowanceReport(asOf: asOf)
        for row in allowanceRows(db, asOf):
          report.lines.add AllowanceLine(
            grade: gradeOfText(row.grade),
            loans: int(row.loans),
            base: moneyOfText(row.base),
            rateMicro: row.rateMicro,
            allowance: moneyOfText(row.allowance),
          )
        var lines = newJArray()
        for line in report.lines:
          lines.add %*{
            "grade": $line.grade,
            "loans": line.loans,
            "base": line.base.toDecimalString,
            "rateMicro": line.rateMicro,
            "allowance": line.allowance.toDecimalString,
          }
        # `mixedRates` = golongan yang punya lebih dari satu tarif pada tanggal itu. Ini bukan
        # galat skema (snapshot menyimpan tarif per pinjaman), tetapi operator perlu melihatnya.
        var mixed = newJArray()
        for grade in mixedRates(report):
          mixed.add %($grade)
        payload = %*{
          "asOf": report.asOf,
          "lines": lines,
          "total": report.allowanceTotal.toDecimalString,
          "baseTotal": report.allowanceBase.toDecimalString,
          "mixedRates": mixed,
        })
  except ValueError:
    req.respondProblem(pkInternal, "Internal Server Error",
      "laporan penyisihan gagal dihitung karena data tidak konsisten")
    return
  except DbError:
    req.respondProblem(pkInternal, "Internal Server Error", "laporan penyisihan gagal dihitung")
    return

  if forbidden:
    req.respondProblem(pkForbidden, "Forbidden",
      "izin " & permissionLendingRead & " tidak dipegang pada tingkat institusi")
    return
  req.respondJson(200, payload)

proc handleReconciliation*(app: AppContext; req: Request) {.gcsafe.} =
  ## `GET /api/v1/lending/reports/reconciliation` — GL vs subledger **saat ini**.
  ##
  ## Tidak ada `asOf`: cache saldo dan penyisihan terakhir adalah keadaan sekarang, dan
  ## membandingkannya dengan GL tanggal lampau hanya menghasilkan selisih palsu.
  let principalOpt = requirePrincipal(app, req)
  if principalOpt.isNone:
    return
  let principal = principalOpt.get()
  if not requirePermission(app, req, principal, permissionLendingRead):
    return
  let asOf = businessDateIso(app.clock)

  var payload = newJNull()
  var forbidden = false
  try:
    withDbConn(app.pool, proc(db: DbConn) {.gcsafe.} =
      dbCalls:
        if not authorizedAtBranch(db, principal, "", permissionLendingRead):
          forbidden = true
          return
        let recon = Reconciliation(
          loanReceivableGl: glAmount(db, asOf, glLoanReceivable, creditNormal = false),
          loanReceivableSubledger: moneyOfText(loanReceivableSubledger(db)),
          allowanceGl: glAmount(db, asOf, glLoanAllowance, creditNormal = true),
          allowanceSubledger: moneyOfText(allowanceSubledger(db)),
          allowanceWrittenOff: moneyOfText(allowanceWrittenOff(db)),
        )
        payload = %*{
          "asOf": asOf,
          "loanReceivableGl": recon.loanReceivableGl.toDecimalString,
          "loanReceivableSubledger": recon.loanReceivableSubledger.toDecimalString,
          "receivableDiff": recon.receivableDiff.toDecimalString,
          "allowanceGl": recon.allowanceGl.toDecimalString,
          "allowanceSubledger": recon.allowanceSubledger.toDecimalString,
          "allowanceWrittenOff": recon.allowanceWrittenOff.toDecimalString,
          "allowanceDiff": recon.allowanceDiff.toDecimalString,
          "balanced": recon.isBalanced,
        })
  except ValueError:
    req.respondProblem(pkInternal, "Internal Server Error",
      "rekonsiliasi gagal dihitung karena data tidak konsisten")
    return
  except DbError:
    req.respondProblem(pkInternal, "Internal Server Error", "rekonsiliasi gagal dihitung")
    return

  if forbidden:
    req.respondProblem(pkForbidden, "Forbidden",
      "izin " & permissionLendingRead & " tidak dipegang pada tingkat institusi")
    return
  req.respondJson(200, payload)
