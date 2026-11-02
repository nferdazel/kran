## Aturan golongan setelah restrukturisasi (O-123, D-197) — murni, tanpa I/O.
##
## DPD tidak cukup untuk menilai pinjaman yang direstrukturisasi: jadwal barunya jatuh tempo di masa
## depan, jadi DPD selalu 0 dan penilaian berbasis DPD saja akan selalu bilang "lancar". Acuan
## POJK 1/2024 (Kualitas Aset BPR) menetapkan:
##
##   - sebelumnya **diragukan/macet** → paling tinggi **kurang lancar**;
##   - sebelumnya **lancar/DPK/kurang lancar** → **tidak berubah**;
##   - boleh menjadi **lancar** setelah tidak ada tunggakan selama 3 kali periode pembayaran
##     berturut-turut (jumlahnya parameter `lending.restructure.clean_periods`).
##
## Modul ini hanya menyimpan **batas atas** dan menerapkannya. Konsekuensinya: penilaian yang lebih
## buruk dari batas tetap boleh (tunggakan baru setelah restrukturisasi harus terlihat), sedangkan
## penilaian yang lebih baik ditahan sampai periode bersihnya cukup.

import ./collectibility

proc capFor*(previous: Collectibility): Collectibility =
  ## Batas atas golongan sesudah restrukturisasi, dari golongan sebelum restrukturisasi.
  case previous
  of colDoubtful, colLoss: colSubstandard
  else: previous

proc capForUngraded*(): Collectibility =
  ## Pinjaman yang belum pernah dinilai tidak punya pembanding "sebelum". Sikap konservatif:
  ## naik paling tinggi ke kurang lancar, sama seperti pinjaman yang sebelumnya diragukan/macet.
  colSubstandard

proc capApplication*(candidate: Collectibility; cap: Collectibility; cleanPeriods: int;
    requiredCleanPeriods: int): Collectibility =
  ## Terapkan batas atas. `candidate` adalah golongan dari DPD jadwal aktif.
  ##
  ## `cleanPeriods` adalah jumlah angsuran terakhir yang dibayar tepat waktu berturut-turut pada
  ## jadwal aktif. Begitu cukup, batas dilepas dan penilaian kembali normal — pinjaman yang benar-
  ## benar membaik tidak tertahan selamanya di kurang lancar.
  if requiredCleanPeriods <= 0 or cleanPeriods >= requiredCleanPeriods:
    return candidate
  if ord(candidate) < ord(cap): cap else: candidate
