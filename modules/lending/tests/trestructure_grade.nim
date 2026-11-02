## Aturan golongan pasca-restrukturisasi (O-123, D-197).

import std/unittest

import ../domain/[collectibility, restructure_grade]

suite "restructure grade: batas atas golongan":
  test "sebelumnya diragukan/macet → paling tinggi kurang lancar":
    check capFor(colDoubtful) == colSubstandard
    check capFor(colLoss) == colSubstandard

  test "sebelumnya lancar/DPK/kurang lancar → batasnya golongan itu sendiri":
    check capFor(colCollectible) == colCollectible
    check capFor(colSpecialMention) == colSpecialMention
    check capFor(colSubstandard) == colSubstandard

  test "pinjaman belum pernah dinilai memakai sikap konservatif, bukan tebakan":
    check capForUngraded() == colSubstandard

  test "perbaikan ditahan sampai periode bersih cukup":
    check capApplication(colCollectible, colSubstandard, 0, 3) == colSubstandard
    check capApplication(colCollectible, colSubstandard, 2, 3) == colSubstandard
    check capApplication(colSpecialMention, colSubstandard, 0, 3) == colSubstandard

  test "penurunan tetap boleh terlihat walau batas berlaku":
    # Tunggakan baru setelah restrukturisasi harus tercatat; batas hanya menahan perbaikan.
    check capApplication(colDoubtful, colSubstandard, 0, 3) == colDoubtful
    check capApplication(colLoss, colSubstandard, 2, 3) == colLoss

  test "batas dilepas setelah periode bersih terpenuhi":
    check capApplication(colCollectible, colSubstandard, 3, 3) == colCollectible
    check capApplication(colCollectible, colSpecialMention, 4, 3) == colCollectible

  test "batas golongan sendiri tidak menahan apa pun":
    check capApplication(colCollectible, colCollectible, 0, 3) == colCollectible
