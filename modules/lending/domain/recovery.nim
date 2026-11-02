## Pemulihan pasca hapus buku (O-122, T-176) — murni, tanpa I/O.
##
## Setelah hapus buku, piutang sudah dibebankan dan saldo pinjaman nol. Uang yang masuk belakangan
## dicatat sebagai **pendapatan**, bukan pengurangan piutang (D-191). Yang dihitung di sini hanya
## batas kumulatif: total yang sudah dipulihkan tidak boleh melebihi nilai yang dihapusbukukan,
## per komponen. Tanpa batas ini, satu pinjaman bisa "dipulihkan" berkali-kali dan laporan
## pendapatan memuat angka yang tidak pernah diterima.
##
## Invarian: tidak ada komponen negatif, total > 0, dan setiap komponen `<= sisa` komponen itu.

import kernel/[money, result]

const recoveryErrCode* = "LEN-1008"

proc recoveryErr(msg: string): AppError {.inline.} =
  appError(recoveryErrCode, "error.lending.recovery", aekValidation, msg)

type
  RecoveryComponents* = object
    principal*: Money
    interest*: Money
    penalty*: Money

  RecoveryPlan* = object
    request*: RecoveryComponents
    total*: Money

proc components*(principal, interest, penalty: Money): RecoveryComponents {.inline.} =
  RecoveryComponents(principal: principal, interest: interest, penalty: penalty)

proc totalOf*(value: RecoveryComponents): Money {.inline.} =
  value.principal + value.interest + value.penalty

proc remaining*(writtenOff, recovered: RecoveryComponents): RecoveryComponents =
  ## Sisa yang masih boleh dipulihkan. Nilai negatif (data lama/rusak) dijepit ke nol supaya
  ## pemeriksaan berikutnya menolak, bukan melempar.
  proc rest(a, b: Money): Money {.inline.} =
    let diff = a - b
    if diff.isNegative: zero() else: diff
  RecoveryComponents(
    principal: rest(writtenOff.principal, recovered.principal),
    interest: rest(writtenOff.interest, recovered.interest),
    penalty: rest(writtenOff.penalty, recovered.penalty),
  )

proc planRecovery*(request, writtenOff, recovered: RecoveryComponents): AppResult[RecoveryPlan] =
  ## `writtenOff` = komponen yang dihapusbukukan (`lending.writeoff`), `recovered` = yang sudah
  ## dipulihkan sebelumnya. Permintaan yang melebihi sisa ditolak, bukan dipotong diam-diam: nominal
  ## yang dikirim harus sama dengan yang tercatat di jurnal.
  if request.principal.isNegative or request.interest.isNegative or request.penalty.isNegative:
    return err[RecoveryPlan, AppError](recoveryErr("komponen pemulihan tidak boleh negatif"))
  let total = request.totalOf()
  if not total.isPositive:
    return err[RecoveryPlan, AppError](recoveryErr("tidak ada nilai pemulihan"))
  let left = remaining(writtenOff, recovered)
  let names = [("pokok", request.principal, left.principal),
               ("bunga", request.interest, left.interest),
               ("denda", request.penalty, left.penalty)]
  for (label, asked, available) in names:
    if asked > available:
      return err[RecoveryPlan, AppError](recoveryErr(
        "pemulihan " & label & " melebihi sisa yang dihapusbukukan (" &
          toDecimalString(available) & ")"))
  ok[RecoveryPlan, AppError](RecoveryPlan(request: request, total: total))
