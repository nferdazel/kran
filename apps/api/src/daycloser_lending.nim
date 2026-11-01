## Task `lending.dpd_regrade` (T-166) untuk kerangka day-close (spec §11.6 "kolektibilitas").
##
## **Apa yang dihitung.** Untuk setiap pinjaman `ACTIVE`, hari tunggakan (DPD) dihitung dari tanggal
## jatuh tempo angsuran **tertua yang belum lunas** terhadap tanggal buku, lalu dipetakan ke golongan
## memakai ambang parameter `lending.collectibility.dpd_bounds` (seed `[90, 120, 180]`, D-180 butir 2).
## Pinjaman yang seluruh angsurannya lunas dinilai lancar (DPD 0) — statusnya tetap `ACTIVE` sampai
## ada keputusan penutupan akad (D-183).
##
## **Kenapa snapshot, bukan hanya kolom.** `lending.collectibility_snapshot` ber-PK
## `(loan_id, business_date)`: menjalankan task dua kali pada tanggal buku yang sama tidak menambah
## baris, tidak menerbitkan event kedua, dan tidak menggeser nilai historis. Kolom
## `lending.loan.collectibility` hanya nilai **terkini** untuk laporan/UI; sumber kebenaran per
## tanggal adalah snapshot.
##
## **Kenapa tidak kritis.** Penilaian golongan tidak memindahkan uang dan tidak menghitung penyisihan;
## kegagalannya tidak boleh menahan penutupan buku. PPAP (T-167) yang akan membuat jurnal — dan task
## itu yang harus kritis karena menyentuh angka laporan keuangan.
##
## **Idempoten**: PK snapshot menolak baris kedua; event `CollectibilityChanged` hanya diterbitkan
## bila golongan benar-benar berubah (termasuk dari `NULL` = belum pernah dinilai). Menjalankan ulang
## tanggal yang sama tidak mengubah angka maupun jumlah event.
##
## Kode kegagalan (stabil, dipakai UI/runbook):
##   DAY-370 daftar pinjaman gagal dibaca (bisa diulang)
##   DAY-371 halaman pinjaman gagal dibaca (bisa diulang)
##   DAY-372 parameter ambang DPD tidak terbaca / bentuknya salah
##   DAY-373 data pinjaman rusak (tanggal jatuh tempo tidak sah)
##   DAY-374 penilaian gagal disimpan (bisa diulang)

import std/[json, options]

import db_connector/db_postgres

import "platform-lib/db/pool"

import kernel/[clock, dayclose, ids, paramkey, result]
import kernel/generated/paramkeys
import platform/domain/[audit, event, scope]
import platform/infrastructure/[audit_repo, outbox_repo, param_repo]

import lending/domain/collectibility
import lending/infrastructure/regrade_repo

import daycloser/domain/[registry, types]

import ./daycloser_common

const
  regradeTaskId* = "lending.dpd_regrade"

type
  RegradeAbort = object of CatchableError
    ## Kegagalan yang bukan I/O: parameter rusak atau data pinjaman tidak bisa dipakai. Menaikkannya
    ## membatalkan transaksi chunk, jadi tidak ada snapshot setengah jadi.
    code*: string

proc abort(code, message: string): ref RegradeAbort =
  result = newException(RegradeAbort, message)
  result.code = code

proc dpdBounds(db: DbConn; ctx: TaskContext): seq[int] =
  ## Ambang pada tanggal buku, bukan salinan saat proses start: kebijakan yang berlaku hari itu yang
  ## dipakai menilai hari itu.
  var value: JsonNode
  try:
    value = activeValueJson(db, keyString(P_lending_collectibility_dpd_bounds), ctx.businessDate,
      lookupFor(institutionScope()))
  except ValueError as e:
    raise abort("DAY-372", "parameter lending.collectibility.dpd_bounds tidak terbaca: " & e.msg)
  let parsed = parseDpdBounds(value)
  if not parsed.isOk:
    raise abort("DAY-372", parsed.error.details)
  parsed.val

proc countRegradeChunks(pool: DbPool; chunkSize: int): Result[int, TaskError] =
  ## Halaman dihitung dari populasi stabil (`ACTIVE`), bukan dari jumlah yang akan berubah: jumlah
  ## yang berubah baru diketahui setelah DPD dihitung per pinjaman.
  try:
    let total = pool.withConn(proc(db: DbConn): int64 = countActiveLoans(db))
    if chunkSize < 1:
      raise newException(ValueError, "chunk size harus >= 1")
    ok[int, TaskError](int((total + int64(chunkSize) - 1) div int64(chunkSize)))
  except IOError as e:
    err[int, TaskError](taskError("DAY-370", "jumlah pinjaman berjalan gagal dibaca: " & e.msg,
      retryable = true))

proc runRegradeChunk(pool: DbPool; clock: Clock; ctx: TaskContext; chunk: Chunk): TaskResult =
  var items: seq[RegradeCandidate]
  var bounds: seq[int]
  try:
    let loaded = pool.withConn(proc(db: DbConn): tuple[items: seq[RegradeCandidate];
        bounds: seq[int]] =
      (regradeCandidatesPage(db, chunk.chunkNo * ctx.chunkSize, ctx.chunkSize), dpdBounds(db, ctx)))
    items = loaded.items
    bounds = loaded.bounds
  except RegradeAbort as e:
    return err[TaskOutcome, TaskError](taskError(e.code, e.msg))
  except IOError as e:
    return err[TaskOutcome, TaskError](taskError("DAY-371",
      "halaman pinjaman gagal dibaca: " & e.msg, retryable = true))

  var graded = 0
  var unchanged = 0
  var skipped = 0
  var changed: seq[string] = @[]
  try:
    discard pool.withTx(proc(db: DbConn): int =
      for candidate in items:
        let dpd =
          if candidate.oldestUnpaidDue.len == 0:
            0
          else:
            let gap = daysPastDue(candidate.oldestUnpaidDue, ctx.businessDate)
            if not gap.isOk:
              raise abort("DAY-373", "pinjaman " & $candidate.loanId & ": " & gap.error.details)
            gap.val
        let graded2 = gradeOf(dpd, bounds)
        if not graded2.isOk:
          # Mustahil bila `parseDpdBounds` lolos, tetapi jangan diam-diam memakai golongan lain.
          raise abort("DAY-372", graded2.error.details)
        let grade = graded2.val

        let inserted = insertSnapshot(db, candidate.loanId, ctx.businessDate, dpd, grade)
        if not inserted:
          # Tanggal buku itu sudah dinilai (task dijalankan ulang): jangan menimpa, jangan mengulang
          # event.
          inc skipped
          continue
        updateCollectibility(db, candidate.loanId, grade)
        inc graded
        if candidate.previous.isNone or candidate.previous.get() != grade:
          changed.add($candidate.loanId)
          discard appendEvent(db, newOutboxEvent(newId(clock), "CollectibilityChanged",
            "lending.loan", $candidate.loanId,
            "lending.collectibility:" & $candidate.loanId & ":" & ctx.businessDate,
            %*{"loanId": $candidate.loanId, "businessDate": ctx.businessDate, "dpd": dpd,
               "grade": $grade,
               "previousGrade": (if candidate.previous.isNone: newJNull()
            else: %($candidate.previous.get())),
               "dpdBounds": bounds}))
        else:
          inc unchanged
      1)
  except RegradeAbort as e:
    return err[TaskOutcome, TaskError](taskError(e.code, e.msg))
  except IOError as e:
    return err[TaskOutcome, TaskError](taskError("DAY-374",
      "penilaian kolektibilitas gagal disimpan: " & e.msg, retryable = true))

  # Satu audit per chunk berisi daftar pinjaman yang berubah: satu audit per pinjaman akan
  # melipatgandakan jejak tanpa menambah informasi (D-170 memakai pola yang sama).
  if changed.len > 0:
    try:
      discard pool.withConn(proc(db: DbConn): int =
        let actx = ctlAuditContext(clock, "task " & regradeTaskId)
        discard appendAudit(db, newAuditEntry(actx, "lending.collectibility.regrade",
          "daycloser_run", ctx.runId, clock, businessDate = ctx.businessDate,
          after = %*{"businessDate": ctx.businessDate, "chunkNo": chunk.chunkNo,
                     "changed": changed, "dpdBounds": bounds}))
        1)
    except IOError as e:
      return err[TaskOutcome, TaskError](taskError("DAY-374",
        "audit penilaian kolektibilitas gagal ditulis: " & e.msg, retryable = true))

  ok[TaskOutcome, TaskError](okOutcome(%*{
    "loans": items.len, "graded": graded, "unchanged": unchanged, "skipped": skipped,
    "changed": changed.len, "dpdBounds": bounds, "businessDate": ctx.businessDate}))

proc registerLendingTasks*(reg: Registry; pool: DbPool) =
  let clock = systemClock()

  # Tidak kritis: penilaian golongan tidak memindahkan uang dan tidak menghitung penyisihan.
  # PPAP (T-167) yang membuat jurnal dan karena itu harus kritis.
  reg.register DayCloseTask(
    id: regradeTaskId,
    module: "lending",
    levels: {clEOD},
    kind: tkProcess,
    dependsOn: @[],
    critical: false,
    idempotency: imPerBusinessDate,
    partition: psByChunkCount,
    requiredParams: @["lending.collectibility.dpd_bounds"],
    countChunks: proc(ctx: TaskContext; chunkSize: int): Result[int, TaskError] =
    countRegradeChunks(pool, chunkSize),
    run: proc(ctx: TaskContext; chunk: Chunk): TaskResult =
    runRegradeChunk(pool, clock, ctx, chunk))
