## Harness property test deterministik (spec §20; tanpa dependensi property-test eksternal).
##
## Seed tetap (bisa di-override lewat `setPropSeed`), iterasi default 500. Saat gagal:
## cetak seed + iterasi + counterexample, lalu `fail`.
##
## Nama berkas **tidak** diawali `t` agar tidak dijalankan sebagai berkas test oleh `./task`.

import std/random
import std/unittest

type
  ## Kegagalan property yang membawa counterexample.
  PropFailure* = object of ValueError

var
  propSeed*: int64 = 0x5EED_C0DE'i64
  propIterations*: int = 500

proc setPropSeed*(s: int64) =
  ## Override seed (determinisme tetap; untuk reproduksi).
  propSeed = s

proc setPropIterations*(n: int) =
  ## Override jumlah iterasi.
  propIterations = n

template checkProp*(cond: bool, counterexample: string) =
  ## Periksa invariant; bila gagal, angkat `PropFailure` berisi counterexample.
  if not bool(cond):
    raise newException(PropFailure, counterexample)

proc runProp*(name: string, body: proc(rng: var Rand) {.closure.}) =
  ## Jalankan `body` `propIterations` kali dengan RNG deterministik.
  var rng = initRand(propSeed)
  for iter in 0 ..< propIterations:
    try:
      body(rng)
    except PropFailure as e:
      echo "PROPERTY FAIL: ", name, " seed=", propSeed, " iterasi=", iter
      echo "  counterexample: ", e.msg
      fail()
    except CatchableError as e:
      echo "PROPERTY FAIL: ", name, " seed=", propSeed, " iterasi=", iter
      echo "  error tak terduga: ", e.name, " - ", e.msg
      fail()

proc randInt64*(rng: var Rand, lo, hi: int64): int64 =
  ## Bilangan acak pada rentang inklusif.
  rng.rand(lo .. hi)
