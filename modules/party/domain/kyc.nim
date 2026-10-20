## Profil KYC & riwayat rating risiko (T-071, spec §8, §18.2).
##
## Semua ambang/waktu berlaku berasal dari parameter (`party.kyc.*`): tingkat risiko yang dikenal,
## tingkat awal, dan jeda re-KYC per tingkat. Penilaian di sini **manual** oleh petugas; skor
## otomatis dari perilaku transaksi bukan lingkup modul ini.

import std/[json, options, strutils, times]

import kernel/ids

const
  maxLevelLength* = 32   # nomagic:ok batas teknis kolom party.kyc_profile.risk_level
  maxReasonLength* = 500 # nomagic:ok batas teknis kolom party.risk_rating.reason
  monthsPerYear* = 12    # nomagic:ok invarian kalender

type
  KycStatus* = enum
    ksPending = "PENDING"
    ksVerified = "VERIFIED"
    ksRejected = "REJECTED"

  KycProfile* = object
    partyId*: Id
    status*: KycStatus
    riskLevel*: string
    riskAssessedAt*: string ## ISO instant; "" bila belum pernah dinilai
    nextReviewDue*: string  ## ISO `yyyy-MM-dd`; "" bila tidak dijadwalkan
    createdAt*: string

  RiskAssessment* = object
    ratingId*: Id
    partyId*: Id
    level*: string
    reason*: string
    assessedAt*: string
    assessedBy*: string

proc parseKycStatus*(raw: string): Option[KycStatus] =
  for s in KycStatus:
    if $s == raw.strip.toUpperAscii:
      return some(s)
  none(KycStatus)

proc parseRiskLevel*(raw: string, allowed: openArray[string]): Option[string] =
  ## Tingkat risiko sah = anggota `party.kyc.risk_levels` (perbandingan case-insensitive).
  ## Yang dikembalikan **selalu huruf besar** supaya rating tersimpan satu bentuk (pola yang sama
  ## dengan jenis dokumen), walau parameter ditulis dengan gaya huruf berbeda.
  let t = raw.strip.toUpperAscii
  if t.len == 0 or t.len > maxLevelLength:
    return none(string)
  for entry in allowed:
    if entry.strip.toUpperAscii == t:
      return some(t)
  none(string)

proc validateReason*(raw: string): string =
  ## Alasan wajib: penilaian risiko/penyimpanan dokumen tanpa alasan tidak bisa diaudit.
  let t = raw.strip
  if t.len == 0:
    raise newException(ValueError, "alasan wajib diisi")
  if t.len > maxReasonLength:
    raise newException(ValueError, "alasan melebihi batas panjang")
  t

proc reviewMonthsOf*(monthsByLevel: JsonNode, level: string): int =
  ## Jeda re-KYC (bulan) untuk satu tingkat risiko dari parameter `party.kyc.review_months`.
  if monthsByLevel.isNil:
    raise newException(ValueError, "parameter party.kyc.review_months tidak terbaca")
  var found = 0
  case monthsByLevel.kind
  of JObject:
    for k, v in monthsByLevel:
      if k.toUpperAscii == level.toUpperAscii:
        if v.kind != JInt:
          raise newException(ValueError,
            "jeda re-KYC untuk " & level & " bukan angka di parameter")
        found = v.getInt
  else:
    raise newException(ValueError, "parameter party.kyc.review_months harus objek")
  if found <= 0:
    raise newException(ValueError, "tidak ada jeda re-KYC untuk tingkat risiko " & level)
  found

proc reviewDueDate*(fromIso: string, months: int): string =
  ## Tanggal + N bulan; hari dijepit ke akhir bulan bila bulan tujuan lebih pendek
  ## (mis. 31 Jan + 1 bulan = 28/29 Feb). Format hasil `yyyy-MM-dd`.
  if months <= 0:
    raise newException(ValueError, "jumlah bulan re-KYC harus positif")
  let base = parse(fromIso, "yyyy-MM-dd")
  let totalMonths = base.year * monthsPerYear + (base.month.ord - 1) + months
  let year = totalMonths div monthsPerYear
  let month = Month(totalMonths mod monthsPerYear + 1)
  let day = min(base.monthday, getDaysInMonth(month, year))
  format(dateTime(year, month, day), "yyyy-MM-dd")
