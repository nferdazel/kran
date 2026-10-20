## Jurnal double-entry (T-073): bentuk jurnal, keseimbangan, dan jurnal pembalik.
##
## Yang ada di sini hanya invarian akuntansi (minimal 2 baris, tepat satu sisi per baris, total
## debit = total kredit). Nilai bisnis (akun mana, berapa) datang dari posting rule/T-074 dan
## parameter, bukan dari kode.

import std/strutils

import kernel/[ids, money]

const
  minJournalLines* = 2           ## invarian double-entry: satu debit + satu kredit
  maxJournalLines* = 999         # nomagic:ok batas teknis kolom line_no (1..999)
  maxIdempotencyKeyLength* = 200 # nomagic:ok batas teknis kolom idempotency_key
  maxSourceEventLength* = 100    # nomagic:ok batas teknis kolom source_event

type
  JournalLine* = object
    lineNo*: int
    glAccount*: string
    branchId*: Id
    debit*: Money
    credit*: Money

  Journal* = object
    journalId*: Id
    businessDate*: string ## ISO `yyyy-MM-dd`
    valueDate*: string    ## ISO `yyyy-MM-dd`
    sourceEvent*: string
    sourceRef*: Id
    idempotencyKey*: string
    reversalOf*: string   ## "" bila bukan jurnal pembalik
    recordedAt*: string   ## ISO-8601 UTC
    lines*: seq[JournalLine]

proc totalDebit*(lines: openArray[JournalLine]): Money =
  for l in lines:
    result = result + l.debit

proc totalCredit*(lines: openArray[JournalLine]): Money =
  for l in lines:
    result = result + l.credit

proc isBalanced*(lines: openArray[JournalLine]): bool =
  totalDebit(lines) == totalCredit(lines)

proc validateSourceEvent*(raw: string): string =
  let s = raw.strip
  if s.len == 0:
    raise newException(ValueError, "sourceEvent wajib diisi")
  if s.len > maxSourceEventLength:
    raise newException(ValueError, "sourceEvent melebihi batas panjang")
  s

proc validateIdempotencyKey*(raw: string): string =
  ## Kunci idempotensi dari pemanggil (header). Wajib: tanpa kunci, event yang dikirim ulang akan
  ## menghasilkan jurnal ganda. Spasi/kontrol ditolak agar kunci tidak "hamper sama".
  let s = raw.strip
  if s.len == 0:
    raise newException(ValueError, "Idempotency-Key wajib diisi")
  if s.len > maxIdempotencyKeyLength:
    raise newException(ValueError, "Idempotency-Key melebihi batas panjang")
  for ch in s:
    if ord(ch) < ord(' ') or ord(ch) == ord('\x7F'):
      raise newException(ValueError, "Idempotency-Key memuat karakter kontrol")
  s

proc validateJournalLines*(lines: openArray[JournalLine]): seq[JournalLine] =
  ## Bentuk yang sah: 2..999 baris, `line_no` unik dan berurutan bebas, akun terisi, nominal tidak
  ## negatif, **tepat satu sisi** > 0 per baris, dan total debit = total kredit.
  if lines.len < minJournalLines:
    raise newException(ValueError, "jurnal harus punya minimal " & $minJournalLines & " baris")
  if lines.len > maxJournalLines:
    raise newException(ValueError, "jurnal melebihi batas baris")
  var seen: seq[int]
  for l in lines:
    if l.lineNo < 1 or l.lineNo > maxJournalLines:
      raise newException(ValueError, "nomor baris di luar rentang 1.." & $maxJournalLines)
    if l.lineNo in seen:
      raise newException(ValueError, "nomor baris ganda: " & $l.lineNo)
    seen.add l.lineNo
    if l.glAccount.strip.len == 0:
      raise newException(ValueError, "akun GL baris " & $l.lineNo & " wajib diisi")
    if minorUnits(l.debit) < 0 or minorUnits(l.credit) < 0:
      raise newException(ValueError, "nominal baris " & $l.lineNo & " tidak boleh negatif")
    let debitSide = not l.debit.isZero()
    let creditSide = not l.credit.isZero()
    if debitSide == creditSide:
      raise newException(ValueError,
        "baris " & $l.lineNo & " harus tepat satu sisi (debit atau kredit)")
    result.add l
  if not isBalanced(result):
    raise newException(ValueError, "jurnal tidak seimbang: total debit <> total kredit")

proc reversalLinesOf*(lines: openArray[JournalLine]): seq[JournalLine] =
  ## Baris pembalik: debit dan kredit ditukar, nomor baris diurutkan ulang 1..n.
  for i, l in lines:
    result.add JournalLine(lineNo: i + 1, glAccount: l.glAccount,
      branchId: l.branchId, debit: l.credit, credit: l.debit)


const
  maxReversalReasonLength* = 500 # nomagic:ok batas ukuran permintaan (kolom audit `text` tanpa batas)

proc validateReversalReason*(raw: string): string =
  ## Alasan pembalik wajib: koreksi jurnal adalah kontrol finansial, bukan edit diam-diam.
  let r = raw.strip
  if r.len == 0:
    raise newException(ValueError, "alasan wajib diisi")
  if r.len > maxReversalReasonLength:
    raise newException(ValueError, "alasan melebihi batas panjang")
  r
