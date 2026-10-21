## Kunci idempotensi + sidik jari permintaan (T-084, D-098).
##
## Nilai-nilai ini teknis: tidak ada aturan bisnis di sini. Yang menyimpan/mereplay adalah
## `infrastructure/idempotency_repo`; yang memutuskan adalah pemanggil (composition root).

import std/strutils

import nimcrypto/[sha2, utils]

const
  maxIdempotencyKeyLength* = 200 # nomagic:ok batas kolom `platform.idempotency_key.key`

type
  ## Hasil keputusan penyimpanan klaim. `idemProceed` berarti pemanggil harus menjalankan operasi
  ## bisnis lalu menutup klaim; tiga nilai lain berarti operasi **tidak** dijalankan.
  IdempotencyDecision* = enum
    idemProceed, idemReplay, idemMismatch, idemInFlight

proc validateIdempotencyKey*(raw: string): string =
  ## Kunci dari header. Spasi di tepi dipangkas; kunci kosong/terlalu panjang/berkarakter kontrol
  ## ditolak supaya dua permintaan tidak dianggap "hampir sama".
  let s = raw.strip
  if s.len == 0:
    raise newException(ValueError, "Idempotency-Key wajib diisi")
  if s.len > maxIdempotencyKeyLength:
    raise newException(ValueError, "Idempotency-Key melebihi batas panjang")
  for ch in s:
    if ord(ch) < ord(' ') or ord(ch) == ord('\x7F'):
      raise newException(ValueError, "Idempotency-Key memuat karakter kontrol")
  s

proc requestHash*(body: string): string =
  ## SHA-256 heksadesimal huruf kecil dari isi permintaan. Dipakai untuk membedakan "kunci sama,
  ## isi beda" (409) dari replay yang sah.
  var ctx: sha256
  ctx.init()
  ctx.update(body)
  let digest = ctx.finish()
  ctx.clear()
  utils.toHex(digest.data, lowercase = true)
