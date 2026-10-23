## Domain murni modul `teller` (T-093): sesi kas teller, vault, dan arus kas laci (spec §9.2/§11.6).
##
## Yang ada di sini hanya bentuk dan aritmetika kas (expected/variance) + validasi struktural.
## **Tidak ada angka bisnis** (limit kas, nominal maksimum) — parameter pemilik belum ditetapkan
## (T-088 §8 butir 1); jangan mengarang nilainya di kode (spec §10, AGENTS.md §1.2).
##
## Tanpa float: seluruh nominal lewat tipe `Money` (kernel/money). Tanpa jurnal GL: T-093 tidak
## menyentuh buku besar (lihat `docs/ACCEPTED-LIMITS.md`).

import std/[options, strutils]

import kernel/[ids, money]

const
  ## Batas teknis kolom `teller.teller_session.note`, bukan kebijakan bisnis.
  maxSessionNoteLength* = 200 # nomagic:ok batas teknis kolom note

type
  ## Status sesi kas (cermin CHECK kolom DB).
  TellerSessionStatus* = enum
    tssOpen = "OPEN"
    tssClosed = "CLOSED"

  ## Tipe arus kas laci (cermin CHECK kolom DB). Hanya dua: opening/counted = kolom sesi.
  CashMovementType* = enum
    cmCashIn = "CASH_IN"
    cmCashOut = "CASH_OUT"

  TellerSession* = object
    sessionId*: Id
    branchId*: Id
    tellerUserId*: Id
    businessDate*: string ## ISO `yyyy-MM-dd`
    status*: TellerSessionStatus
    openingFloat*: Money
    openedAt*: string     ## ISO-8601 UTC
    openedBy*: Id
    ## Kolom penutup: `none` selama sesi `OPEN` (ditegakkan CHECK tabel).
    expectedCash*: Option[Money]
    countedCash*: Option[Money]
    variance*: Option[Money]
    note*: string         ## "" = tidak diisi
    closedAt*: string     ## "" = belum ditutup
    closedBy*: string     ## "" = belum ditutup

  CashMovement* = object
    movementId*: Id
    sessionId*: Id
    movementType*: CashMovementType
    amount*: Money
    transactionId*: Id
    businessDate*: string
    occurredAt*: string
    createdBy*: string

proc parseTellerSessionStatus*(raw: string): TellerSessionStatus =
  let s = raw.strip.toUpperAscii()
  for st in TellerSessionStatus:
    if $st == s:
      return st
  raise newException(ValueError, "status sesi teller tidak dikenal: " & raw)

proc parseCashMovementType*(raw: string): CashMovementType =
  let s = raw.strip.toUpperAscii()
  for t in CashMovementType:
    if $t == s:
      return t
  raise newException(ValueError, "tipe cash_movement tidak dikenal: " & raw)

proc validateOpeningFloat*(amount: Money): Money =
  ## Opening float boleh nol (kas awal kosong), tetapi tidak boleh negatif. Nilai di luar itu
  ## adalah permintaan tidak sah, bukan aturan bisnis.
  if amount.isNegative():
    raise newException(ValueError, "openingFloat tidak boleh negatif")
  amount

proc validateCountedCash*(amount: Money): Money =
  ## Kas fisik yang dihitung boleh nol, tidak boleh negatif (kas fisik negatif = salah hitung).
  if amount.isNegative():
    raise newException(ValueError, "countedCash tidak boleh negatif")
  amount

proc validateTopUpAmount*(amount: Money): Money =
  ## Nominal top-up vault (T-107) wajib **positif**: menambah nol tidak mengubah apa pun (salah
  ## pakai) dan nominal negatif adalah penarikan — operasi yang tidak punya endpoint.
  ## Batas atas tidak ditetapkan di sini: limit kas adalah kebijakan pemilik (O-099), dan batas
  ## teknisnya adalah kapasitas `Money` (int64 unit 10⁻⁴) yang sudah ditolak `moneyFromString`.
  if not amount.isPositive():
    raise newException(ValueError, "amount top-up harus lebih besar dari nol")
  amount

proc validateSessionNote*(raw: string): string =
  let s = raw.strip
  if s.len > maxSessionNoteLength:
    raise newException(ValueError, "note melebihi " & $maxSessionNoteLength & " karakter")
  s

proc newOpenSession*(sessionId, branchId, tellerUserId: Id, businessDate: string,
                     openingFloat: Money, openedBy: Id, note = ""): TellerSession =
  ## Sesi baru berstatus `OPEN`; kolom penutup belum ada.
  if $branchId == "":
    raise newException(ValueError, "cabang sesi wajib diisi")
  if $tellerUserId == "":
    raise newException(ValueError, "teller sesi wajib diisi")
  discard validateOpeningFloat(openingFloat)
  TellerSession(
    note: validateSessionNote(note),
    sessionId: sessionId,
    branchId: branchId,
    tellerUserId: tellerUserId,
    businessDate: businessDate,
    status: tssOpen,
    openingFloat: openingFloat,
    openedBy: openedBy)

proc newCashMovement*(movementId, sessionId: Id, movementType: CashMovementType,
                      amount: Money, transactionId: Id, businessDate: string,
                      createdBy: string): CashMovement =
  ## Baris arus laci. `amount` wajib positif (arah ditentukan `movementType`).
  if amount <= zero():
    raise newException(ValueError, "nominal cash_movement harus lebih besar dari nol")
  CashMovement(
    movementId: movementId,
    sessionId: sessionId,
    movementType: movementType,
    amount: amount,
    transactionId: transactionId,
    businessDate: businessDate,
    createdBy: createdBy)

proc cashDeltaOf*(movementType: CashMovementType, amount: Money): Money =
  ## Dampak satu movement ke kas laci: `CASH_IN` menambah, `CASH_OUT` mengurangi.
  case movementType
  of cmCashIn: amount
  of cmCashOut: -amount

proc netMovementOf*(movements: openArray[CashMovement]): Money =
  ## Σ dampak seluruh movement sesi (saldo arus, belum termasuk opening float).
  var acc = zero()
  for m in movements:
    acc = acc + cashDeltaOf(m.movementType, m.amount)
  acc

proc expectedCashOf*(openingFloat, cashIn, cashOut: Money): Money =
  ## Kas yang **seharusnya** ada di laci pada saat tutup: float awal + seluruh setoran − penarikan.
  ## Hanya formula, bukan aturan kebijakan; `cashIn`/`cashOut` berasal dari agregat movement sesi.
  openingFloat + cashIn - cashOut

proc varianceOf*(countedCash, expectedCash: Money): Money =
  ## Selisih kas fisik vs perkiraan. Positif = kas **lebih**, negatif = kas **kurang**.
  ## Bukan 409: selisih tetap dicatat + diaudit, tidak menolak penutupan (keputusan T-093).
  countedCash - expectedCash
