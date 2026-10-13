## Harness property-test kecil (spec §20: "property-based").
##
## **Bukan** framework: cukup untuk invarian kernel. Kalau nanti requirement naik
## (shrinking, coverage), evaluasi `testament`/pustaka property — dan tulis ADR-nya.
##
## Aturan penting: **deterministik**. Seed tetap, sehingga kegagalan bisa diulang persis.

import std/random

type
  Gen*[T] = proc(r: var Rand): T

const defaultSeed* = 0x5EE5'i64
const defaultIterations* = 500

proc forAll*[T](
    name: string,
    iterations: int,
    gen: Gen[T],
    check: proc(x: T): bool {.closure.},
    describe: proc(x: T): string {.closure.},
    seed: int64 = defaultSeed,
): bool =
  ## Mengembalikan `false` (dan mencetak counterexample) bila ada satu kasus gagal.
  var r = initRand(seed)
  for i in 0 ..< iterations:
    let x = gen(r)
    if not check(x):
      echo "  PROP GAGAL [", name, "] seed=", seed, " iterasi=", i,
        " nilai=", describe(x)
      return false
  true

proc overflowRaises*(f: proc(): void {.closure.}): bool =
  ## Benar bila `f` menaikkan ValueError (dipakai untuk membuktikan overflow/0 ditolak).
  try:
    f()
  except ValueError, RangeDefect:
    return true
  false
