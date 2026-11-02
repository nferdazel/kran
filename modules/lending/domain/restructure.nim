## Restrukturisasi pinjaman (T-168, keputusan pemilik 1 Nov 2026) — murni, tanpa I/O.
##
## Restrukturisasi **menyusun jadwal versi baru** dari sisa pokok; jadwal lama tidak diubah, hanya
## diarsipkan (trigger `lending/0089` melarang mengubah kewajiban yang sudah dibayar, dan itu benar).
##
## Dua hal yang diputuskan pemilik dan **bukan** ditebak di sini:
##   - tunggakan bunga/denda jadwal lama **dilepas**, dasar jadwal baru = sisa **pokok**
##     (bunga diakui saat dibayar, jadi tidak ada pendapatan yang perlu dibalik);
##   - DPD dihitung dari jadwal aktif, yang jatuh temponya di masa depan. Kolektibilitas **tidak**
##     otomatis kembali lancar: `restructure_grade.nim` menahan golongan di batas atas dari golongan
##     sebelum restrukturisasi sampai periode pembayaran bersih cukup (O-123, D-197, POJK 1/2024).
## Pelepasan tunggakan bunga/denda tetap sikap pilot yang belum diverifikasi compliance.
##
## Penomoran angsuran **berlanjut** dari nomor terakhir versi sebelumnya: `lending.payment_allocation`
## menunjuk `(payment_id, installment_no)` tanpa versi, jadi nomor yang dipakai ulang akan membuat
## alokasi lama terbaca sebagai alokasi jadwal baru.

import kernel/[money, rate, result]

import ./loan, ./schedule

const restructureErrCode* = "LEN-1006"

proc restructureErr(msg: string): AppError {.inline.} =
  appError(restructureErrCode, "error.lending.restructure", aekValidation, msg)

type
  RestructurePlan* = object
    rows*: seq[Installment]
    versionNo*: int
    maturityOn*: string ## jatuh tempo angsuran terakhir versi baru

proc restructurePlan*(
    outstanding: Money;
    annualRate: Rate;
    tenorMonths: int;
    scheduleMethod: ScheduleMethod;
    firstDueOn: string;
    firstNo: int;
    versionNo: int;
): AppResult[RestructurePlan] =
  ## `firstNo` = nomor angsuran pertama versi baru (lanjutan nomor terakhir), `versionNo` = versi
  ## jadwal. Versi 1 adalah jadwal pencairan, jadi restrukturisasi selalu >= 2.
  if not outstanding.isPositive:
    return err[RestructurePlan, AppError](restructureErr(
      "sisa pokok harus lebih dari 0; pinjaman tanpa sisa kewajiban tidak perlu direstrukturisasi"))
  if firstNo < 1:
    return err[RestructurePlan, AppError](restructureErr("nomor angsuran pertama harus >= 1"))
  if versionNo < 2:
    return err[RestructurePlan, AppError](restructureErr(
      "versi jadwal restrukturisasi harus >= 2 (versi 1 = jadwal pencairan)"))
  let built = buildSchedule(outstanding, annualRate, tenorMonths, scheduleMethod, firstDueOn)
  if not built.isOk:
    return err[RestructurePlan, AppError](restructureErr(built.error.details))
  var rows = built.val
  for row in rows.mitems:
    row.no = row.no + firstNo - 1
  ok[RestructurePlan, AppError](RestructurePlan(
    rows: rows,
    versionNo: versionNo,
    maturityOn: (if rows.len == 0: "" else: rows[^1].dueOn),
  ))
