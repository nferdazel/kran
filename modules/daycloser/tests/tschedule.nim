## Unit test jadwal penutupan otomatis (T-139b), murni tanpa DB.

import std/unittest

import ../api

suite "jadwal: bentuk jam":
  test "HH:MM sah dibaca apa adanya":
    check parseClockTime("00:00").toMinutes == 0
    check parseClockTime("23:30").toMinutes == 23 * 60 + 30
    check parseClockTime("07:05").toMinutes == 7 * 60 + 5
    check parseClockTime(" 09:15 ").toMinutes == 9 * 60 + 15

  test "bentuk lain ditolak, bukan ditebak":
    for bad in ["", "2330", "24:00", "23:60", "7:05", "ab:cd", "12:3", "12:345"]:
      expect ValueError:
        discard parseClockTime(bad)

suite "jadwal: menit lokal":
  test "offset positif menggeser ke depan":
    # 23:30 UTC + 7 jam = 06:30 keesokan harinya (dibungkus ke hari lokal).
    check localMinutesOfDay(23 * 60 + 30, 7 * 60) == 6 * 60 + 30

  test "offset negatif memundurkan, tetap dalam 0..1439":
    check localMinutesOfDay(30, -60) == 23 * 60 + 30
    check localMinutesOfDay(0, 0) == 0

  test "offset ekstrem tetap dibungkus":
    check localMinutesOfDay(720, 840) == 720 + 840 - 1440
    check localMinutesOfDay(0, -840) == 1440 - 840

suite "jadwal: jatuh tempo":
  test "sebelum jam jadwal belum jatuh tempo, tepat sesudahnya jatuh tempo":
    check not dueNow(23 * 60 + 29, 23 * 60 + 30)
    check dueNow(23 * 60 + 30, 23 * 60 + 30)
    check dueNow(0, 0)

  test "jam yang sudah lewat berkali-kali tetap jatuh tempo (idempoten oleh penjaga run)":
    check dueNow(23 * 60 + 59, 1 * 60)
