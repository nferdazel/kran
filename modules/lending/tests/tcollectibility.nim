## Unit test kolektibilitas `lending` (T-166).
##
## Yang diuji adalah **pemetaan**, bukan angkanya: ambang datang dari parameter (D-180 butir 2), jadi
## test memakai dua set ambang berbeda untuk membuktikan kode benar-benar membaca parameter, bukan
## menanam angka bank di dalam dirinya.

import std/[json, unittest]

import kernel/result

import ../domain/collectibility

suite "lending collectibility: hari tunggakan":
  test "jatuh tempo hari ini = 0, masa depan bukan tunggakan negatif":
    check daysPastDue("2026-11-01", "2026-11-01").val == 0
    check daysPastDue("2026-12-01", "2026-11-01").val == 0
    check daysPastDue("2026-10-31", "2026-11-01").val == 1

  test "dihitung per hari kalender, termasuk lintas bulan dan tahun":
    check daysPastDue("2026-01-01", "2026-01-31").val == 30
    check daysPastDue("2025-12-15", "2026-01-15").val == 31
    check daysPastDue("2026-02-28", "2026-03-01").val == 1

  test "tanggal tidak sah ditolak, bukan dianggap nol":
    check not daysPastDue("2026-13-01", "2026-11-01").isOk
    check not daysPastDue("2026-11-01", "bukan-tanggal").isOk

suite "lending collectibility: golongan":
  const bankBounds = [90, 120, 180]

  test "batas tiap golongan tepat di ambangnya":
    check gradeOf(0, bankBounds).val == colCollectible
    check gradeOf(1, bankBounds).val == colSpecialMention
    check gradeOf(90, bankBounds).val == colSpecialMention
    check gradeOf(91, bankBounds).val == colSubstandard
    check gradeOf(120, bankBounds).val == colSubstandard
    check gradeOf(121, bankBounds).val == colDoubtful
    check gradeOf(180, bankBounds).val == colDoubtful
    check gradeOf(181, bankBounds).val == colLoss

  test "ambang dari parameter benar-benar dipakai, bukan angka bawaan":
    # Kebijakan yang lebih ketat: 30/60/90. Golongan harus bergeser tanpa mengubah kode.
    const strict = [30, 60, 90]
    check gradeOf(31, strict).val == colSubstandard
    check gradeOf(31, bankBounds).val == colSpecialMention
    check gradeOf(365, strict).val == colLoss

  test "ambang tidak sah ditolak, bukan dipakai sebagian":
    check not gradeOf(10, [90, 120]).isOk # jumlah salah
    check not gradeOf(10, [90, 90, 180]).isOk # tidak naik ketat
    check not gradeOf(10, [0, 120, 180]).isOk # nol bukan ambang

suite "lending collectibility: parameter JSON":
  test "array bilangan bulat naik diterima":
    let parsed = parseDpdBounds(%*[90, 120, 180])
    check parsed.isOk
    check parsed.val == @[90, 120, 180]

  test "bentuk salah ditolak dengan sebab yang bisa dibaca operator":
    check not parseDpdBounds(%*["90", "120", "180"]).isOk
    check not parseDpdBounds(%*[90, 120]).isOk
    check not parseDpdBounds(%*[180, 120, 90]).isOk
    check not parseDpdBounds(%*{"bounds": [90, 120, 180]}).isOk
    check not parseDpdBounds(newJNull()).isOk
