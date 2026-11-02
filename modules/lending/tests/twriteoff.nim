## Unit test hapus buku `lending` (T-168): pembagian penyisihan vs beban.
##
## Invariannya satu dan tidak boleh longgar: `allowanceApplied + expense == total` tepat, penyisihan
## tidak pernah dipakai melebihi saldonya sendiri maupun melebihi nilai yang dihapus, dan tidak ada
## komponen negatif. Uang tidak boleh hilang di antara dua akun.

import std/unittest

import kernel/[money, result]

import ../domain/writeoff

proc mn(s: string): Money =
  let m = moneyFromString(s)
  doAssert m.isOk, "nilai uji tidak sah: " & s
  m.val

proc split(principal, interest, penalty, allowance: string): WriteOffSplit =
  let s = writeoffSplit(mn(principal), mn(interest), mn(penalty), mn(allowance))
  doAssert s.isOk, (if s.isOk: "" else: s.error.details)
  s.val

suite "lending writeoff: pembagian penyisihan dan beban":
  test "penyisihan dipakai lebih dulu, sisanya menjadi beban":
    let s = split("5000000.00", "1000000.00", "50000.00", "3000000.00")
    check s.total == mn("6050000.00")
    check s.allowanceApplied == mn("3000000.00")
    check s.expense == mn("3050000.00")
    check s.allowanceApplied + s.expense == s.total

  test "tanpa penyisihan, seluruhnya menjadi beban":
    let s = split("1000000.00", "0.00", "0.00", "0.00")
    check s.allowanceApplied == zero()
    check s.expense == mn("1000000.00")

  test "penyisihan melebihi nilai hapus buku: dipakai sebatas nilai":
    let s = split("1000000.00", "0.00", "0.00", "5000000.00")
    check s.allowanceApplied == mn("1000000.00")
    check s.expense == zero()

  test "komponen negatif dan total nol ditolak":
    check not writeoffSplit(mn("-1.00"), zero(), zero(), zero()).isOk
    check not writeoffSplit(zero(), mn("-1.00"), zero(), zero()).isOk
    check not writeoffSplit(zero(), zero(), mn("-1.00"), zero()).isOk
    check not writeoffSplit(zero(), zero(), zero(), zero()).isOk

  test "saldo penyisihan negatif ditolak, bukan dianggap nol":
    check not writeoffSplit(mn("1000.00"), zero(), zero(), mn("-1.00")).isOk
