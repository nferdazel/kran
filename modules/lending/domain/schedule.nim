## Mesin jadwal angsuran (T-162, D-180 butir 1): flat, efektif (saldo menurun), anuitas.
##
## Semua perhitungan bilangan bulat: `Money` dalam sen, `Rate` dalam micro (1e6 = 100%), tanpa
## `float` (AGENTS.md §1.3). Bunga satu periode dibulatkan **sekali** dengan half-to-even, sama
## seperti akrual simpanan (D-152 amendemen) supaya tidak ada bias ke atas.
##
## Pembulatan pecahan sen tidak boleh hilang: setiap metode menaruh sisa pembulatan di baris
## **terakhir**, sehingga `Σ principalDue == principal` tepat — bukan "hampir sama". Jadwal yang
## totalnya meleset satu sen akan memaksa pembayaran terakhir menutup selisih yang tidak pernah
## disepakati anggota.
##
## Batas berkas ini: hanya membentuk nilai jadwal. Menyimpannya ke DB milik T-164 (pencairan);
## denda keterlambatan T-165; kolektibilitas/PPAP T-166/T-167.

import kernel/[businessdate, checkedint, money, rate, result]

import ./loan

const
  monthsInYear* = 12 ## nomagic:ok jumlah bulan per tahun (kalender, bukan angka bisnis)
                     ## Kode error berkas ini dipisah dari `loan.nim`: pesan "jadwal tidak bisa dibentuk" dan
                     ## "parameter pinjaman tidak sah" ditangani operator dengan cara berbeda.
  scheduleErrCode* = "LEN-1002"

proc scheduleErr(msg: string): AppError {.inline.} =
  appError(scheduleErrCode, "error.lending.schedule", aekValidation, msg)

proc interestForMonth*(principal: Money; annualRate: Rate): Money =
  ## Bunga satu periode bulanan dari saldo pokok `principal`: `principal × rate / 12`, satu
  ## pembulatan half-to-even. Dekomposisi `principal = q·(12·10⁶) + rem` menjaga perkalian tetap
  ## di dalam int64: `q·micro + round(rem·micro / (12·10⁶))` — hasilnya identik dengan satu
  ## pembulatan langsung karena sisanya sudah dikalikan penyebut yang sama.
  const den = rateDenominator * int64(monthsInYear)
  let
    micro = microUnits(annualRate)
    units = minorUnits(principal)
  if units <= 0 or micro <= 0:
    return zero()
  let
    q = units div den
    rem = units mod den
  money(checkedAdd(checkedMul(q, micro), divRoundHalfEven(checkedMul(rem, micro), den)))

proc totalInterestFlat*(principal: Money; annualRate: Rate; months: int): Money =
  ## Bunga total metode flat: `principal × rate × bulan / 12`, satu pembulatan.
  ## Dekomposisi yang sama dengan `interestForMonth`, hanya penyebutnya dikali `months` di sisi
  ## sisa sehingga `q·micro·bulan` tetap bulat.
  const den = rateDenominator * int64(monthsInYear)
  let
    micro = microUnits(annualRate)
    units = minorUnits(principal)
  if units <= 0 or micro <= 0 or months <= 0:
    return zero()
  let
    q = units div den
    rem = units mod den
  money(checkedAdd(
    checkedMul(checkedMul(q, micro), int64(months)),
    divRoundHalfEven(checkedMul(checkedMul(rem, micro), int64(months)), den),
  ))

proc splitEvenly(total: Money; parts: int): tuple[per: Money; rest: Money] =
  ## Bagi `total` ke `parts` baris, sisa di baris terakhir. `parts > 0` dijamin pemanggil.
  let per = total div int64(parts)
  (per, total - per * int64(parts - 1))

proc addMonths(d: BusinessDate; months: int): BusinessDate =
  ## Tambah bulan kalender dengan **penjepitan** hari: 31 Jan + 1 bulan = 28/29 Feb. Bukan
  ## penambahan 30 hari — tanggal jatuh tempo adalah tanggal kalender, dan anggota membacanya
  ## sebagai "tanggal sekian setiap bulan".
  let
    total = d.year * monthsInYear + (d.month - 1) + months
    year = total div monthsInYear
    month = total mod monthsInYear + 1
  BusinessDate(year: year, month: month, day: min(d.day, daysInMonth(year, month)))

proc dueDates(firstDueOn: BusinessDate; months: int): seq[string] =
  result = newSeq[string](months)
  for k in 0 ..< months:
    result[k] = toIso(addMonths(firstDueOn, k))

proc effectiveRows(principal: Money; annualRate: Rate; months: int): seq[tuple[p, i: Money]] =
  ## Bunga dihitung dari saldo pokok yang benar-benar tersisa; pokok per periode tetap.
  result = newSeq[tuple[p, i: Money]](months)
  let split = splitEvenly(principal, months)
  var outstanding = principal
  for k in 0 ..< months:
    let p = (if k == months - 1: outstanding else: split.per)
    result[k] = (p, interestForMonth(outstanding, annualRate))
    outstanding = outstanding - p

proc simulate(outstanding: Money; annualRate: Rate; months: int; payment: Money): Money =
  ## Sisa pokok setelah `months` angsuran tetap `payment`. Negatif/ngol berarti lunas dalam tenor.
  var left = outstanding
  for _ in 0 ..< months:
    let principalPart = payment - interestForMonth(left, annualRate)
    if principalPart <= zero():
      # Angsuran tidak menutup bunga: pokok tidak pernah turun, jadi tenor tidak akan selesai.
      return left
    left = left - principalPart
  left

proc annuityPayment*(principal: Money; annualRate: Rate; months: int): Money =
  ## Angsuran tetap terkecil yang melunasi pokok dalam `months` periode.
  ##
  ## Rumus baku `A = P·i / (1 − (1+i)^−n)` butuh pangkat pecahan; di sini pencarian biner atas
  ## amortisasi bilangan bulat dipakai supaya hasilnya **tepat** dalam sen tanpa `float` dan tanpa
  ## galat pembulatan yang menumpuk pada pangkat ber-skor besar. Monoton: angsuran lebih besar
  ## selalu menyisakan pokok lebih kecil.
  let
    low0 = principal div int64(months)
    high0 = principal
  if annualRate.isZero:
    return low0
  var
    low = low0
    high = high0
  while low < high:
    let mid = money((minorUnits(low) + minorUnits(high)) div 2)
    if simulate(principal, annualRate, months, mid) <= zero():
      high = mid
    else:
      low = mid + money(1)
  low

proc buildSchedule*(
    principal: Money;
    annualRate: Rate;
    months: int;
    scheduleMethod: ScheduleMethod;
    firstDueOn: string;
): AppResult[seq[Installment]] =
  ## Jadwal angsuran lengkap. `firstDueOn` = jatuh tempo angsuran pertama (`yyyy-MM-dd`).
  if months <= 0:
    return err[seq[Installment], AppError](scheduleErr("tenor harus lebih dari 0 bulan"))
  if minorUnits(principal) <= 0:
    return err[seq[Installment], AppError](scheduleErr("pokok pinjaman harus lebih dari 0"))
  if annualRate.isNegative:
    return err[seq[Installment], AppError](scheduleErr("suku bunga tidak boleh negatif"))
  let start = parseBusinessDate(firstDueOn)
  if not start.isOk:
    return err[seq[Installment], AppError](scheduleErr(
      "tanggal jatuh tempo pertama tidak sah: " & firstDueOn
    ))

  let dates = dueDates(start.val, months)
  var rows: seq[Installment] = @[]

  case scheduleMethod
  of smFlat:
    let
      split = splitEvenly(principal, months)
      totalInterest = totalInterestFlat(principal, annualRate, months)
      perInterest = totalInterest div int64(months)
    for k in 0 ..< months:
      let
        p = (if k == months - 1: split.rest else: split.per)
        i = (if k == months - 1: totalInterest - perInterest * int64(months - 1) else: perInterest)
      rows.add(Installment(
        no: k + 1, dueOn: dates[k], principalDue: p, interestDue: i, penaltyDue: zero()
      ))
  of smEffective:
    let fixedPrincipal = splitEvenly(principal, months)
    var outstanding = principal
    for k in 0 ..< months:
      let
        p = (if k == months - 1: outstanding else: fixedPrincipal.per)
        i = interestForMonth(outstanding, annualRate)
      rows.add(Installment(
        no: k + 1, dueOn: dates[k], principalDue: p, interestDue: i, penaltyDue: zero()
      ))
      outstanding = outstanding - p
  of smAnnuity:
    let payment = annuityPayment(principal, annualRate, months)
    var outstanding = principal
    for k in 0 ..< months:
      let i = interestForMonth(outstanding, annualRate)
      var p = payment - i
      if p > outstanding or k == months - 1:
        # Baris terakhir menutup sisa pokok tepat; selisih pembulatan angsuran tetap berakhir di
        # sini, bukan menggeser pokok baris sebelumnya.
        p = outstanding
      rows.add(Installment(
        no: k + 1, dueOn: dates[k], principalDue: p, interestDue: i, penaltyDue: zero()
      ))
      outstanding = outstanding - p

  ok[seq[Installment], AppError](rows)

proc totalDueOfSchedule*(rows: openArray[Installment]): Money =
  var acc = zero()
  for r in rows:
    acc = acc + totalDue(r)
  acc

proc principalOfSchedule*(rows: openArray[Installment]): Money =
  var acc = zero()
  for r in rows:
    acc = acc + r.principalDue
  acc

proc addMonthsIso*(isoDate: string; months: int): AppResult[string] =
  ## Tanggal + `months` bulan kalender (penjepitan akhir bulan), untuk menghitung jatuh tempo
  ## pertama dari tanggal cair. Dipakai pencairan (T-164) supaya aturan tanggalnya tetap satu.
  let parsed = parseBusinessDate(isoDate)
  if not parsed.isOk:
    return err[string, AppError](scheduleErr("tanggal tidak sah: " & isoDate))
  ok[string, AppError](toIso(addMonths(parsed.val, months)))
