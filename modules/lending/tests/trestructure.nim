## Unit test restrukturisasi `lending` (T-168): bentuk jadwal versi baru.
##
## Yang diuji adalah **kontrak bentuk**, bukan angka produk: sisa pokok harus terurai tepat sama di
## jadwal baru, nomor angsuran berlanjut (tidak memakai ulang nomor jadwal lama), dan versi 1 tidak
## bisa dipakai untuk restrukturisasi.

import std/[sequtils, unittest]

import kernel/[money, rate, result]

import ../domain/[loan, restructure, schedule]

proc mn(s: string): Money =
  let m = moneyFromString(s)
  doAssert m.isOk, "nilai uji tidak sah: " & s
  m.val

proc pct(s: string): Rate =
  let r = rateFromPercentString(s)
  doAssert r.isOk, "persen uji tidak sah: " & s
  r.val

proc plan(outstanding = "6000000.00"; tenor = 6; firstNo = 13; version = 2): RestructurePlan =
  let built = restructurePlan(mn(outstanding), pct("12"), tenor, smFlat, "2027-01-01", firstNo,
    version)
  doAssert built.isOk, (if built.isOk: "" else: built.error.details)
  built.val

suite "lending restructure: jadwal versi baru":
  test "sisa pokok terurai tepat, tanpa kehilangan satu sen":
    let p = plan()
    check p.rows.len == 6
    check p.rows.mapIt(it.principalDue).foldl(a + b, zero()) == mn("6000000.00")
    check p.maturityOn == p.rows[^1].dueOn
    check p.versionNo == 2

  test "nomor angsuran berlanjut, tidak memakai ulang nomor jadwal lama":
    let p = plan(firstNo = 13)
    check p.rows[0].no == 13
    check p.rows[^1].no == 18
    # Nomor 1–12 milik jadwal lama; memakainya lagi akan membuat `payment_allocation` lama
    # menunjuk baris jadwal baru.
    check p.rows.allIt(it.no >= 13)

  test "jadwal baru mulai di masa depan, sehingga DPD kembali nol":
    let p = plan()
    check p.rows[0].dueOn == "2027-01-01"

  test "bentuk tidak sah ditolak, bukan disusun sebagian":
    check not restructurePlan(zero(), pct("12"), 6, smFlat, "2027-01-01", 1, 2).isOk
    check not restructurePlan(mn("-1.00"), pct("12"), 6, smFlat, "2027-01-01", 1, 2).isOk
    check not restructurePlan(mn("1000000.00"), pct("12"), 0, smFlat, "2027-01-01", 1, 2).isOk
    check not restructurePlan(mn("1000000.00"), pct("12"), 6, smFlat, "2027-01-01", 0, 2).isOk
    # Versi 1 = jadwal pencairan; restrukturisasi selalu versi berikutnya.
    check not restructurePlan(mn("1000000.00"), pct("12"), 6, smFlat, "2027-01-01", 1, 1).isOk
    check not restructurePlan(mn("1000000.00"), pct("12"), 6, smFlat, "bukan-tanggal", 1, 2).isOk
