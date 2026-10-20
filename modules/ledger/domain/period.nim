## Periode akuntansi (T-072): rentang inklusif, status, dan validasi bentuk tanggal.
##
## Modul ini tidak memutuskan urutan penutupan (EOD/EOM ada di `daycloser`); yang diputuskan di
## sini hanya bentuk rentang yang sah dan status yang dikenal.

import std/[options, strutils, times]

import kernel/ids

type
  PeriodStatus* = enum
    psOpen = "OPEN"
    psClosed = "CLOSED"

  Period* = object
    periodId*: Id
    startsOn*: string ## ISO `yyyy-MM-dd` (inklusif)
    endsOn*: string   ## ISO `yyyy-MM-dd` (inklusif)
    status*: PeriodStatus
    closedAt*: string ## ISO-8601 UTC; "" bila belum ditutup
    closedBy*: string ## UUID; "" bila belum ditutup
    createdAt*: string

proc parsePeriodStatus*(raw: string): Option[PeriodStatus] =
  for s in PeriodStatus:
    if $s == raw.strip.toUpperAscii:
      return some(s)
  none(PeriodStatus)

proc parseIsoDate*(raw, field: string): string =
  ## Tanggal `YYYY-MM-DD` yang benar-benar ada (31 Feb ditolak di sini, bukan oleh cast DB).
  let s = raw.strip
  if s.len == 0:
    raise newException(ValueError, field & " wajib diisi")
  try:
    discard parse(s, "yyyy-MM-dd")
  except TimeParseError:
    raise newException(ValueError, field & " harus tanggal YYYY-MM-DD yang sah")
  s

proc validateRange*(startsOnRaw, endsOnRaw: string): tuple[startsOn, endsOn: string] =
  ## Rentang inklusif; urutan terbalik ditolak. Pemanggil sudah memvalidasi bentuk lewat
  ## `parseIsoDate`, tetapi fungsi ini memvalidasi ulang agar tidak bergantung pada ingatan.
  let startsOn = parseIsoDate(startsOnRaw, "startsOn")
  let endsOn = parseIsoDate(endsOnRaw, "endsOn")
  if parse(endsOn, "yyyy-MM-dd") < parse(startsOn, "yyyy-MM-dd"):
    raise newException(ValueError, "endsOn tidak boleh lebih awal dari startsOn")
  (startsOn, endsOn)

const
  ## Batas **ukuran permintaan** (justifikasi), bukan batas kolom: `platform.audit_log.reason`
  ## bertipe `text`. Angka ini menjaga badan permintaan tetap wajar.
  maxReasonLength* = 500 # nomagic:ok batas ukuran permintaan, bukan nilai bisnis

proc validateCloseReason*(raw: string): string =
  ## Menutup periode adalah kontrol finansial: alasannya wajib dan ikut jejak audit.
  let r = raw.strip
  if r.len == 0:
    raise newException(ValueError, "alasan wajib diisi")
  if r.len > maxReasonLength:
    raise newException(ValueError, "alasan melebihi batas panjang")
  r
