## Domain murni modul `product` (T-076): katalog produk parametrik & versi effective-dated.
##
## Yang ada di sini hanya bentuk dan invarian struktural (kode, tipe, jendela tanggal, binding
## parameter). **Tidak ada angka bisnis**: nilai atribut datang dari parameter (binding) dan
## divalidasi terhadap definisi parameter di composition root.

import std/[json, strutils]

import kernel/[businessdate, ids, result]

type
  ProductType* = enum
    ptSavings = "SAVINGS"
    ptTimeDeposit = "TIME_DEPOSIT"
    ptLoan = "LOAN"
    ptFinancing = "FINANCING"

  VersionStatus* = enum
    ## Siklus hidup versi (D-099 + D-119): diajukan `DRAFT`, lalu diputuskan sekali menjadi
    ## `ACTIVE` (approve) atau `REJECTED` (reject). Tidak ada transisi lain.
    vsDraft = "DRAFT"
    vsActive = "ACTIVE"
    vsRejected = "REJECTED"

  Product* = object
    productId*: Id
    code*: string
    name*: string
    productType*: ProductType
    createdAt*: string

  ProductVersion* = object
    versionId*: Id
    productId*: Id
    versionNo*: int
    effectiveFrom*: string ## ISO `yyyy-MM-dd`
    effectiveTo*: string   ## "" = terbuka ke atas
    status*: VersionStatus
    maker*: Id             ## pengaju (D-099); tidak diserialisasi ke API
    publishedAt*: string   ## waktu pencatatan versi (nama historis, D-119)
    approvedAt*: string    ## "" = belum diputuskan
    rejectReason*: string  ## "" = tidak ditolak

  ParamBinding* = object
    paramKey*: string
    value*: JsonNode

const
  codeMinLength* = 2             # nomagic:ok batas format kode produk (bukan nilai bisnis)
  codeMaxLength* = 32            # nomagic:ok batas teknis format kode
  nameMaxLength* = 120           # nomagic:ok batas teknis kolom nama
  bindingKeyPrefix* = "product." ## atribut produk tidak boleh menunjuk parameter keamanan/platform

proc parseProductType*(raw: string): ProductType =
  let s = raw.strip.toUpperAscii()
  for t in ProductType:
    if $t == s:
      return t
  raise newException(ValueError, "productType tidak dikenal: " & raw)

proc parseVersionStatus*(raw: string): VersionStatus =
  let s = raw.strip.toUpperAscii()
  for st in VersionStatus:
    if $st == s:
      return st
  raise newException(ValueError, "status versi tidak dikenal: " & raw)

proc canTransition*(fromStatus, toStatus: VersionStatus): bool =
  ## Satu-satunya transisi yang sah: DRAFT → ACTIVE/REJECTED. Dipakai test & handler sebagai
  ## cermin aturan trigger `guard_version_update` di DB.
  fromStatus == vsDraft and toStatus in {vsActive, vsRejected}

proc assertDistinctActors*(maker, checker: Id) =
  ## Maker-checker (D-099): pemutus harus orang lain daripada pengaju. Cermin CHECK
  ## `product_version_self_approval_chk`.
  if maker == checker:
    raise newException(ValueError, "checker harus berbeda dari maker (pengesahan sendiri ditolak)")

proc validateCode*(raw: string): string =
  ## Kode produk stabil (dipakai di API/referensi): huruf besar/angka, boleh `. _ -`.
  let s = raw.strip.toUpperAscii()
  if s.len < codeMinLength or s.len > codeMaxLength:
    raise newException(ValueError, "kode produk harus " & $codeMinLength & "–" &
      $codeMaxLength & " karakter")
  for i, ch in s:
    let isAlnum = ch in {'A' .. 'Z', '0' .. '9'}
    if i == 0 and not isAlnum:
      raise newException(ValueError, "kode produk harus diawali huruf/angka")
    if not isAlnum and ch notin {'.', '_', '-'}:
      raise newException(ValueError, "kode produk hanya boleh huruf, angka, '.', '_', '-'")
  s

proc validateName*(raw: string): string =
  let s = raw.strip
  if s.len == 0:
    raise newException(ValueError, "nama produk wajib diisi")
  if s.len > nameMaxLength:
    raise newException(ValueError, "nama produk melebihi " & $nameMaxLength & " karakter")
  s

proc isoDate(raw, field: string): BusinessDate =
  let r = parseBusinessDate(raw.strip)
  if r.isErr:
    raise newException(ValueError, field & " bukan tanggal ISO (yyyy-MM-dd) yang sah")
  r.value()

proc validateWindow*(effectiveFrom, effectiveTo: string): tuple[fromIso, toIso: string] =
  ## Jendela versi **inklusif** `[from, to]`, konsisten dengan periode ledger; `to` kosong =
  ## terbuka ke atas.
  let start = isoDate(effectiveFrom, "effectiveFrom")
  result.fromIso = toIso(start)
  if effectiveTo.strip.len == 0:
    return (result.fromIso, "")
  let finish = isoDate(effectiveTo, "effectiveTo")
  if not (start <= finish):
    raise newException(ValueError, "effectiveTo tidak boleh sebelum effectiveFrom")
  result.toIso = toIso(finish)

proc validateBindings*(bindings: openArray[ParamBinding]): seq[ParamBinding] =
  ## Minimal satu binding; kunci unik dan hanya di namespace `product.`; nilai tidak null.
  if bindings.len == 0:
    raise newException(ValueError, "produk wajib punya minimal satu atribut parameter")
  for b in bindings:
    let key = b.paramKey.strip
    if key.len == 0:
      raise newException(ValueError, "kunci parameter binding wajib diisi")
    if not key.startsWith(bindingKeyPrefix):
      raise newException(ValueError,
        "atribut produk harus parameter berawalan `" & bindingKeyPrefix & "`: " & key)
    if b.value.isNil or b.value.kind == JNull:
      raise newException(ValueError, "nilai binding kosong untuk " & key)
    for seen in result:
      if seen.paramKey == key:
        raise newException(ValueError, "kunci parameter binding ganda: " & key)
    result.add ParamBinding(paramKey: key, value: b.value)
