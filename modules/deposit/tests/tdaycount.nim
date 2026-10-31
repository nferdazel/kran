## Unit test domain `deposit` basis hitung hari bunga (T-138a): parse, pembagi, dan selisih hari.
##
## Murni (tanpa DB): hanya kalender. Nominal bunga tidak diuji di sini karena memang tidak ada
## di `domain/daycount.nim` (pekerjaan terpisah, HUMAN-REVIEW-REQUIRED menurut D-152).

import std/unittest

import kernel/[businessdate, result]
import ../api

suite "deposit: parse basis day-count":
  test "nilai enum diterima, case-insensitive":
    check parseDayCountBasis("ACT_365") == dcAct365
    check parseDayCountBasis("ACT_360") == dcAct360
    check parseDayCountBasis("THIRTY_360") == dcThirty360
    check parseDayCountBasis("act_365") == dcAct365
    check parseDayCountBasis("Act_360") == dcAct360
    check parseDayCountBasis(" thirty_360 ") == dcThirty360

  test "nilai tak dikenal ditolak, tanpa fallback ke basis pertama":
    expect ValueError:
      discard parseDayCountBasis("ACT_364")
    expect ValueError:
      discard parseDayCountBasis("")
    expect ValueError:
      discard parseDayCountBasis("30/360")

  test "nilai string sama persis dengan parameter product.savings.day_count_basis":
    check $dcAct365 == "ACT_365"
    check $dcAct360 == "ACT_360"
    check $dcThirty360 == "THIRTY_360"

suite "deposit: pembagi tahun":
  test "ACT/365, ACT/360, 30/360":
    check basisDays(dcAct365) == 365
    check basisDays(dcAct360) == 360
    check basisDays(dcThirty360) == 360

suite "deposit: selisih hari ACT (kalender riil)":
  test "satu tahun penuh dan bulan kabisat":
    check accrualDays(dcAct365, "2026-01-01", "2027-01-01") == 365
    check accrualDays(dcAct365, "2024-01-01", "2025-01-01") == 366
    check accrualDays(dcAct365, "2026-01-01", "2026-02-01") == 31
    check accrualDays(dcAct365, "2024-02-28", "2024-03-01") == 2
    check accrualDays(dcAct365, "2026-02-28", "2026-03-01") == 1

  test "tanggal sama = 0 hari":
    check accrualDays(dcAct365, "2026-06-15", "2026-06-15") == 0
    check accrualDays(dcAct360, "2026-06-15", "2026-06-15") == 0

  test "ACT/360 menghitung hari yang sama dengan ACT/365":
    # Basis hanya memengaruhi pembagi, bukan hitungan hari.
    for pair in [
      ("2026-01-01", "2027-01-01"),
      ("2024-02-28", "2024-03-01"),
      ("2026-01-31", "2026-03-31"),
      ("2024-02-29", "2025-02-28"),
    ]:
      check accrualDays(dcAct360, pair[0], pair[1]) == accrualDays(dcAct365, pair[0], pair[1])

  test "selisih hari ACT sama dengan daysBetween kernel":
    let cases = [
      ("2026-01-01", "2026-12-31"), ("2024-03-01", "2024-03-01"),
      ("2025-12-31", "2026-01-01"),
    ]
    for c in cases:
      let a = value(parseBusinessDate(c[0]))
      let b = value(parseBusinessDate(c[1]))
      check accrualDays(dcAct365, c[0], c[1]) == daysBetween(a, b)

  test "urutan terbalik ditolak":
    expect ValueError:
      discard accrualDays(dcAct365, "2026-02-01", "2026-01-01")

  test "tanggal tidak valid ditolak":
    expect ValueError:
      discard accrualDays(dcAct365, "2026-02-30", "2026-03-01")
    expect ValueError:
      discard accrualDays(dcAct365, "15-06-2026", "2026-06-16")

suite "deposit: 30/360 US (NASD) golden":
  # Semua ekspektasi diturunkan dari aturan di docstring, bukan dari tebakan:
  #   D1 = 31 → 30; D2 = 31 dan D1 ∈ {30,31} → D2 = 30; keduanya akhir Februari → D2 = 30.
  test "31 Januari ke 28 Februari 2026 = 28":
    # D1 31→30; D2 = 28 bukan 31 → 30*(2-1) + (28-30) = 28.
    check accrualDays(dcThirty360, "2026-01-31", "2026-02-28") == 28

  test "31 Januari ke 31 Maret 2026 = 60":
    # D1 31→30; D2 31→30 → 30*(3-1) + (30-30) = 60.
    check accrualDays(dcThirty360, "2026-01-31", "2026-03-31") == 60

  test "31 Januari 2026 ke 31 Januari 2027 = 360":
    # D1 31→30; D2 31→30 → 360*1 + 0 + (30-30) = 360 (satu tahun 30/360).
    check accrualDays(dcThirty360, "2026-01-31", "2027-01-31") == 360

  test "31 Agustus ke 30 September 2026 = 30":
    # D1 31→30; D2 = 30 → 30*1 + (30-30) = 30.
    check accrualDays(dcThirty360, "2026-08-31", "2026-09-30") == 30

  test "30 Januari ke 31 Januari 2026 = 0":
    # D2 = 31 dan D1 = 30 → D2 dipaksa 30, jadi nol hari. Ini konsekuensi aturan NASD yang
    # dipakai; 30E/360 (tanpa aturan kedua) akan memberi 1 hari. Perbedaan inilah yang perlu
    # dikonfirmasi compliance (lihat docstring).
    check accrualDays(dcThirty360, "2026-01-30", "2026-01-31") == 0

  test "keduanya hari terakhir Februari → D2 = 30":
    # 29 Feb 2024 dan 28 Feb 2025 sama-sama akhir Februari (kabisat vs bukan): D1 tetap 29,
    # D2 28→30 → 360*1 + 0 + (30-29) = 361. Tanpa aturan ketiga hasilnya 359.
    check accrualDays(dcThirty360, "2024-02-29", "2025-02-28") == 361
    # 28 Feb 2026 dan 28 Feb 2027 sama-sama akhir Februari: D1 28, D2 28→30 → 360 + 2 = 362.
    check accrualDays(dcThirty360, "2026-02-28", "2027-02-28") == 362

  test "akhiran Februari pada satu sisi saja tidak memicu aturan ketiga":
    # Awal bukan akhir Februari → D2 tetap 28 → 30*1 + (28-15) = 43.
    check accrualDays(dcThirty360, "2026-01-15", "2026-02-28") == 43

  test "tanggal sama = 0 dan urutan terbalik ditolak":
    check accrualDays(dcThirty360, "2026-03-15", "2026-03-15") == 0
    expect ValueError:
      discard accrualDays(dcThirty360, "2026-03-31", "2026-01-31")

suite "deposit: sifat umum":
  test "hari akrual tidak pernah negatif bila startsOn <= endsOn":
    let cases = [
      ("2024-02-29", "2024-02-29"), ("2025-12-31", "2026-01-01"),
      ("2024-02-29", "2025-02-28"), ("2026-01-31", "2026-03-31"),
    ]
    for b in DayCountBasis:
      for c in cases:
        check accrualDays(b, c[0], c[1]) >= 0

  test "dua rentang bersambung = rentang total (hanya untuk basis ACT)":
    # 30/360 tidak aditif (pembulatan D1/D2 per rentang), jadi tidak diklaim di sini.
    for b in [dcAct365, dcAct360]:
      check accrualDays(b, "2026-01-01", "2026-06-01") +
        accrualDays(b, "2026-06-01", "2027-01-01") == accrualDays(b, "2026-01-01", "2027-01-01")
      check accrualDays(b, "2024-02-28", "2024-03-01") +
        accrualDays(b, "2024-03-01", "2024-04-01") == accrualDays(b, "2024-02-28", "2024-04-01")
