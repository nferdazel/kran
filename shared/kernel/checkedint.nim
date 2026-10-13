## Aritmetika bilangan bulat yang tidak membiarkan overflow lewat **diam-diam**, plus
## pembulatan half-to-even (banker's).
##
## Ini invarian matematis (bukan nilai bisnis), jadi memang boleh ada di kode — dan sengaja
## hanya di satu tempat supaya `Money` (10⁴) dan `Rate` (10⁶) tunduk pada aturan yang sama.
##
## Mengapa penting: pada build release pemeriksaan overflow bawaan Nim nonaktif, sehingga
## `a + b` untuk int64 bisa "membungkus" dan menghasilkan angka yang salah tanpa error.
## Untuk uang/rate itu tidak boleh terjadi (AGENTS.md §1.3).

type
  ArithmeticOverflowError* = object of ValueError

proc overflowError*(what: string): ref ArithmeticOverflowError {.inline.} =
  newException(ArithmeticOverflowError, "melampaui int64: " & what)

proc checkedAdd*(a, b: int64): int64 {.inline.} =
  let s = a +% b
  if ((a xor s) and (b xor s)) < 0:
    raise overflowError("penjumlahan")
  s

proc checkedSub*(a, b: int64): int64 {.inline.} =
  let d = a -% b
  if ((a xor b) and (a xor d)) < 0:
    raise overflowError("pengurangan")
  d

proc checkedMul*(a, b: int64): int64 =
  if a == 0 or b == 0:
    return 0
  let p = a *% b
  if p div b != a:
    raise overflowError("perkalian")
  p

proc checkedNeg*(a: int64): int64 {.inline.} =
  if a == low(int64):
    raise overflowError("negasi")
  -a

proc divRoundHalfEven*(num, den: int64): int64 =
  ## Pembagian bulat dengan pembulatan half-to-even. `den` harus > 0.
  ## Titik 0,5 dibulatkan ke bilangan genap terdekat, termasuk untuk nilai negatif.
  if den <= 0:
    raise newException(ValueError, "divRoundHalfEven: penyebut harus > 0")
  if num == low(int64):
    raise overflowError("pembulatan nilai minimum int64")
  let neg = num < 0
  let n = (if neg: -num else: num)
  var q = n div den
  let r = n mod den
  let twice = r * 2
  if twice > den or (twice == den and (q and 1) == 1):
    inc q
  if neg: -q else: q
