## Alokasi pembayaran angsuran ke baris jadwal (T-165, D-180 butir 4).
##
## Dua hal yang **tidak** diputuskan di sini, karena keduanya parameter/keputusan bisnis:
##   - urutan komponen (pokok/bunga/denda) datang dari parameter `lending.allocation_order`;
##   - urutan baris jadwal (angsuran tertua lebih dulu) adalah aturan akad yang berlaku umum, bukan
##     angka: membayar angsuran terakhir lebih dulu akan membuat tunggakan bulan ini tetap menunggak.
##
## Berkas ini murni: tidak menyentuh DB, tidak memposting jurnal, tidak tahu siapa aktornya. Yang
## dijamin adalah **jumlah**: `Σ lines == amount` tepat, dan tidak ada komponen yang dialokasikan
## melebihi kewajibannya. Sisa pembayaran yang tidak menemukan tujuan adalah kesalahan pemanggil
## (nominal melebihi sisa kewajiban), bukan sisa yang dibiarkan menguap.

import kernel/[ids, money, result]

import ./loan

const paymentErrCode* = "LEN-1003"

proc paymentErr(msg: string): AppError {.inline.} =
  appError(paymentErrCode, "error.lending.payment", aekValidation, msg)

type
  PaymentLine* = object
    ## Satu potongan pembayaran: baris jadwal `installmentNo`, komponen, dan nominalnya.
    installmentNo*: int
    component*: AllocationComponent
    amount*: Money

  Payment* = object
    ## Satu peristiwa bayar. `""` pada tanggal = belum dicatat (dipakai saat membentuk nilai sebelum
    ## id/tanggal buku diketahui).
    paymentId*: Id
    loanId*: Id
    accountId*: Id
    amount*: Money
    principalPaid*: Money
    interestPaid*: Money
    penaltyPaid*: Money
    businessDate*: string

  PaymentPlan* = object
    ## Hasil alokasi. Total per komponen dipakai composition root untuk memposting satu jurnal per
    ## komponen yang **tidak nol** — komponen nol tidak boleh menghasilkan jurnal nol.
    lines*: seq[PaymentLine]
    principal*: Money
    interest*: Money
    penalty*: Money

proc `==`*(a, b: PaymentLine): bool {.inline.} =
  ## Perbandingan struktural untuk test dan pemakaian luar: objek `Money` tidak punya `==` bawaan
  ## untuk tuple/seq, jadi tanpa ini `p.lines == @[...]` tidak bisa dipakai sebagai pembanding.
  a.installmentNo == b.installmentNo and a.component == b.component and a.amount == b.amount

proc dueOf*(inst: Installment; component: AllocationComponent): Money {.inline.} =
  case component
  of acPrincipal: inst.principalDue
  of acInterest: inst.interestDue
  of acPenalty: inst.penaltyDue

proc paidOf*(inst: Installment; component: AllocationComponent): Money {.inline.} =
  case component
  of acPrincipal: inst.paidPrincipal
  of acInterest: inst.paidInterest
  of acPenalty: inst.paidPenalty

proc outstandingOf*(inst: Installment; component: AllocationComponent): Money {.inline.} =
  ## Sisa kewajiban satu komponen. Tidak pernah negatif: CHECK DB menjaga `paid_* <= *_due`, dan
  ## alokasi di bawah juga tidak pernah melewati batas itu.
  let left = dueOf(inst, component) - paidOf(inst, component)
  if left.isNegative: zero() else: left

proc totalOutstanding*(rows: openArray[Installment]): Money =
  ## Sisa kewajiban seluruh jadwal (pokok + bunga + denda yang belum terbayar).
  var acc = zero()
  for row in rows:
    for component in AllocationComponent:
      acc = acc + outstandingOf(row, component)
  acc

proc smaller(a, b: Money): Money {.inline.} =
  if a <= b: a else: b

proc orderProblem(order: openArray[AllocationComponent]): string =
  ## `""` = urutan lengkap dan tanpa duplikat. Diperiksa di sini juga, bukan hanya di
  ## `parseAllocationOrder`: alokasi yang melewatkan satu komponen akan menolak pembayaran yang
  ## sah (sisa tak bertujuan) atau — lebih buruk — diam-diam membebankan komponen yang salah.
  let expected = ord(high(AllocationComponent)) + 1
  if order.len != expected:
    return "urutan alokasi tidak lengkap: " & $order.len & "/" & $expected
  var seen = 0
  for component in order:
    let bit = 1 shl ord(component)
    if (seen and bit) != 0:
      return "komponen alokasi duplikat: " & $component
    seen = seen or bit
  ""

proc allocatePayment*(
    rows: openArray[Installment];
    order: openArray[AllocationComponent];
    amount: Money
): AppResult[PaymentPlan] =
  ## Alokasi `amount` ke `rows` (pemanggil mengurutkan dari jatuh tempo tertua) mengikuti `order`.
  ##
  ## Gagal bila `amount` tidak positif atau melebihi sisa kewajiban: kelebihan bayar belum punya
  ## keputusan bisnis (dikreditkan ke pokok berikutnya? dikembalikan tunai?), dan menebaknya berarti
  ## mengarang aturan uang.
  if amount.isNegative or amount.isZero:
    return err[PaymentPlan, AppError](paymentErr("nominal pembayaran harus lebih dari 0"))
  let orderIssue = orderProblem(order)
  if orderIssue.len > 0:
    return err[PaymentPlan, AppError](paymentErr(orderIssue))

  var
    plan = PaymentPlan()
    remaining = amount
    capacityLeft = totalOutstanding(rows)
  if amount > capacityLeft:
    return err[PaymentPlan, AppError](paymentErr(
      "nominal pembayaran melebihi sisa kewajiban " & toDecimalString(capacityLeft)))

  for row in rows:
    if remaining.isZero:
      break
    for component in order:
      if remaining.isZero:
        break
      let capacity = outstandingOf(row, component)
      if capacity.isZero:
        continue
      let take = smaller(remaining, capacity)
      plan.lines.add(PaymentLine(installmentNo: row.no, component: component, amount: take))
      case component
      of acPrincipal: plan.principal = plan.principal + take
      of acInterest: plan.interest = plan.interest + take
      of acPenalty: plan.penalty = plan.penalty + take
      remaining = remaining - take
      capacityLeft = capacityLeft - take

  if not remaining.isZero:
    # Tidak mungkin terjadi bila `capacityLeft` benar, tetapi dibiarkan eksplisit: uang yang tidak
    # menemukan tujuan lebih baik gagal daripada hilang di antara dua pencatatan.
    return err[PaymentPlan, AppError](paymentErr("sisa pembayaran tidak menemukan tujuan"))
  ok[PaymentPlan, AppError](plan)

proc applyPlan*(rows: var seq[Installment]; plan: PaymentPlan) =
  ## Menulis hasil alokasi ke baris jadwal (permukaan `paid_*`). Dipakai test dan pemanggil yang
  ## menghitung ulang sisa setelah pembayaran; DB tetap sumber kebenaran.
  for line in plan.lines:
    for row in rows.mitems:
      if row.no != line.installmentNo:
        continue
      case line.component
      of acPrincipal: row.paidPrincipal = row.paidPrincipal + line.amount
      of acInterest: row.paidInterest = row.paidInterest + line.amount
      of acPenalty: row.paidPenalty = row.paidPenalty + line.amount
