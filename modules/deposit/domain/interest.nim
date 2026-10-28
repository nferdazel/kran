## Akrual bunga deposito berjangka (T-138c, D-152 + amendemen).
##
## Rumus: `bunga = pokok × rate × hari / basisHari`, dibulatkan **sekali** ke sen dengan
## HALF_EVEN. Keputusan pemilik (28 Okt 2026): satu pembulatan per rentang akrual, bukan per hari,
## supaya tidak ada selisih yang menumpuk terhadap bunga yang dijanjikan di akhir tenor.
##
## Dinyatakan dalam bilangan bulat (sen dan micro-rate, 1e6 = 100%):
##   unit = pokok_sen × micro × hari / (1e6 × basisHari)
## Pembagian dikerjakan bertahap — `(q·DEN + r) → q·micro + round(r·micro / DEN)` — supaya
## perkalian tidak melampaui int64. Karena `q·micro` sudah bulat, hasil akhirnya tetap **satu**
## pembulatan (pembulatan bersifat translasi-invarian terhadap bilangan bulat).
##
## Batas berkas ini sengaja sempit: hanya nominal bunga untuk satu rentang. Tanggal, basis hari,
## status rekening, dan pemilihan rate milik pemanggil (task day-close + parameter produk).

import kernel/[checkedint, money, rate, result]

proc interestErr(msg: string; code = "KRAN-1103"): AppError =
  appError(code, "error.interest.invalid", aekValidation, msg)

proc interestForRange*(principal: Money; rate: Rate; days, basisDays: int): AppResult[Money] =
  ## Bunga untuk `days` hari atas `principal`, dengan `rate` tahunan (persen sebagai `Rate`).
  ## `AppResult` dipakai untuk kondisi yang **bisa terjadi pada data nyata** (nominal melebihi
  ## rentang bilangan), sedangkan argumen yang mustahil (hari ≤ 0, basis ≤ 0, pokok/rate negatif)
  ## adalah `ValueError` — bug pemanggil, bukan data.
  if days <= 0:
    raise newException(ValueError, "jumlah hari akrual harus > 0")
  if basisDays <= 0:
    raise newException(ValueError, "basis hari akrual harus > 0")
  if principal < zero():
    raise newException(ValueError, "pokok negatif tidak diakrualkan")
  if rate.isNegative:
    raise newException(ValueError, "rate negatif tidak diakrualkan")
  if principal == zero() or rate.isZero():
    return ok[Money, AppError](zero())

  let den = checkedMul(rateDenominator, int64(basisDays))
  var scaled: int64
  try:
    scaled = checkedMul(minorUnits(principal), int64(days))
  except ArithmeticOverflowError:
    return err[Money, AppError](interestErr("pokok × hari melampaui batas bilangan"))

  let q = scaled div den
  let r = scaled mod den
  var units: int64
  try:
    units = checkedMul(q, microUnits(rate))
    units = checkedAdd(units, divRoundHalfEven(checkedMul(r, microUnits(rate)), den))
  except ArithmeticOverflowError:
    return err[Money, AppError](interestErr("bunga melampaui batas bilangan"))
  ok[Money, AppError](money(units))
