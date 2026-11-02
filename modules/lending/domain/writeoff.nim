## Hapus buku (T-168) — murni, tanpa I/O.
##
## Hapus buku menutup **seluruh sisa kewajiban** (pokok + bunga + denda; keputusan pemilik 1 Nov
## 2026). Penyisihan yang sudah dibentuk (akun `111`, D-185) dipakai lebih dulu; kekurangannya menjadi
## beban hapus buku (`504`). Pembagian itu satu-satunya hal yang dihitung di sini, dan ia dihitung di
## berkas murni supaya "berapa dari penyisihan, berapa dari beban" bisa diuji tanpa DB.
##
## Invarian yang dijaga: `allowanceApplied + expense == total` tepat, `allowanceApplied` tidak pernah
## melebihi saldo penyisihan maupun total, dan tidak ada komponen negatif. Uang tidak boleh
## "hilang di tengah" antara dua akun.

import kernel/[money, result]

const writeoffErrCode* = "LEN-1007"

proc writeoffErr(msg: string): AppError {.inline.} =
  appError(writeoffErrCode, "error.lending.writeoff", aekValidation, msg)

type
  WriteOffSplit* = object
    principal*: Money
    interest*: Money
    penalty*: Money
    total*: Money
    allowanceApplied*: Money
    expense*: Money

proc smaller(a, b: Money): Money {.inline.} =
  if a < b: a else: b

proc writeoffSplit*(
    principal, interest, penalty, allowance: Money
): AppResult[WriteOffSplit] =
  ## `allowance` = saldo penyisihan yang tersedia untuk pinjaman ini (0 bila belum disisihkan).
  if principal.isNegative or interest.isNegative or penalty.isNegative:
    return err[WriteOffSplit, AppError](writeoffErr(
      "komponen hapus buku tidak boleh negatif"))
  let total = principal + interest + penalty
  if not total.isPositive:
    return err[WriteOffSplit, AppError](writeoffErr(
      "tidak ada sisa kewajiban untuk dihapusbukukan"))
  if allowance.isNegative:
    return err[WriteOffSplit, AppError](writeoffErr(
      "saldo penyisihan tidak boleh negatif"))
  let applied = smaller(allowance, total)
  ok[WriteOffSplit, AppError](WriteOffSplit(
    principal: principal,
    interest: interest,
    penalty: penalty,
    total: total,
    allowanceApplied: applied,
    expense: total - applied,
  ))
