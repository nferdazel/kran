## Unit test pemulihan pasca hapus buku `lending` (O-122, T-176).
##
## Yang dijaga: total pemulihan kumulatif tidak pernah melebihi nilai yang dihapusbukukan per
## komponen, tidak ada komponen negatif, dan total > 0. Nominal yang dikirim pengguna harus sama
## dengan yang dijurnal — karena itu permintaan berlebih ditolak, bukan dipotong diam-diam.

import std/[strutils, unittest]

import kernel/[money, result]

import ../domain/recovery

proc mn(s: string): Money =
  let m = moneyFromString(s)
  doAssert m.isOk, "nilai uji tidak sah: " & s
  m.val

proc plan(request, writtenOff, recovered: RecoveryComponents): AppResult[RecoveryPlan] =
  planRecovery(request, writtenOff, recovered)

proc comp(principal, interest, penalty: string): RecoveryComponents =
  components(mn(principal), mn(interest), mn(penalty))

suite "lending recovery: batas kumulatif":
  test "pemulihan sebagian dalam batas diterima":
    let p = plan(comp("1000000.00", "0.00", "0.00"), comp("5000000.00", "1000000.00", "50000.00"),
      comp("0.00", "0.00", "0.00"))
    check p.isOk
    check p.val.total == mn("1000000.00")

  test "sisa dihitung per komponen, bukan dari total":
    # Pokok sudah penuh dipulihkan, tetapi bunga masih boleh.
    let r = comp("5000000.00", "0.00", "0.00")
    let p = plan(comp("0.00", "400000.00", "0.00"), comp("5000000.00", "1000000.00", "50000.00"), r)
    check p.isOk
    check p.val.total == mn("400000.00")

  test "melebihi sisa komponen ditolak, bukan dipotong":
    let r = comp("4900000.00", "0.00", "0.00")
    let p = plan(comp("200000.00", "0.00", "0.00"), comp("5000000.00", "1000000.00", "50000.00"),
      r)
    check not p.isOk
    check p.error.details.contains("pokok")

  test "denda punya batas sendiri":
    let p = plan(comp("0.00", "0.00", "60000.00"), comp("5000000.00", "1000000.00", "50000.00"),
      comp("0.00", "0.00", "0.00"))
    check not p.isOk

  test "komponen negatif ditolak":
    let p = plan(comp("-1.00", "0.00", "0.00"), comp("5000000.00", "0.00", "0.00"),
      comp("0.00", "0.00", "0.00"))
    check not p.isOk

  test "total nol ditolak":
    let p = plan(comp("0.00", "0.00", "0.00"), comp("5000000.00", "0.00", "0.00"),
      comp("0.00", "0.00", "0.00"))
    check not p.isOk

  test "pemulihan penuh tepat sama dengan nilai hapus buku diterima":
    let p = plan(comp("5000000.00", "1000000.00", "50000.00"),
      comp("5000000.00", "1000000.00", "50000.00"), comp("0.00", "0.00", "0.00"))
    check p.isOk
    check p.val.total == mn("6050000.00")

  test "data lama yang sudah melebihi batas tidak menghasilkan sisa negatif":
    let left = remaining(comp("100.00", "0.00", "0.00"), comp("150.00", "0.00", "0.00"))
    check left.principal == mn("0.00")
