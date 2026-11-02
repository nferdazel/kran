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

import std/[json, options, tables]

import db_connector/db_postgres

import "platform-lib/db/pool"

import kernel/[clock, dayclose, ids, money, paramkey, rate, result]
import kernel/generated/paramkeys
import platform/domain/[audit, event, scope]
import platform/infrastructure/[audit_repo, outbox_repo, param_repo]

import lending/domain/[collectibility, ppap, restructure_grade]
import lending/infrastructure/[ppap_repo, regrade_repo]

import daycloser/domain/[registry, types]

import ./daycloser_common
import ./deposit_posting
import ./posting

const
  regradeTaskId* = "lending.dpd_regrade"
  ppapTaskId* = "lending.ppap_provision"

type
  LendingAbort = object of CatchableError
    ## Kegagalan yang bukan I/O: parameter rusak atau data pinjaman tidak bisa dipakai. Menaikkannya
    ## membatalkan transaksi chunk, jadi tidak ada snapshot setengah jadi.
    code*: string

proc abort(code, message: string): ref LendingAbort =
  result = newException(LendingAbort, message)
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

proc cleanPeriodsRequired(db: DbConn; ctx: TaskContext): int =
  ## Ambang periode pembayaran bersih sebelum batas golongan pasca-restrukturisasi dilepas (O-123).
  ## Dibaca pada tanggal buku, sama seperti ambang DPD.
  var value: JsonNode
  try:
    value = activeValueJson(db, keyString(P_lending_restructure_clean_periods),
      ctx.businessDate, lookupFor(institutionScope()))
  except ValueError as e:
    raise abort("DAY-372", "parameter lending.restructure.clean_periods tidak terbaca: " & e.msg)
  if value.isNil or value.kind != JInt or value.getInt() < 1 or value.getInt() > 12:
    raise abort("DAY-372", "parameter lending.restructure.clean_periods harus bilangan bulat 1..12")
  int(value.getInt())

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
  var cleanPeriods = 0
  try:
    let loaded = pool.withConn(proc(db: DbConn): tuple[items: seq[RegradeCandidate];
        bounds: seq[int]; cleanPeriods: int] =
      (regradeCandidatesPage(db, chunk.chunkNo * ctx.chunkSize, ctx.chunkSize, ctx.businessDate),
       dpdBounds(db, ctx), cleanPeriodsRequired(db, ctx)))
    items = loaded.items
    bounds = loaded.bounds
    cleanPeriods = loaded.cleanPeriods
  except LendingAbort as e:
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
        # Pinjaman yang direstrukturisasi tidak dinilai hanya dari DPD jadwal baru: batas atasnya
        # dari golongan sebelum restrukturisasi, dilepas setelah cukup periode pembayaran bersih
        # (O-123, D-197 — POJK 1/2024).
        let grade =
          if candidate.gradeCap.isNone:
            graded2.val
          else:
            capApplication(graded2.val, candidate.gradeCap.get(), candidate.cleanPeriods,
              cleanPeriods)

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
  except LendingAbort as e:
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


proc ppapRates(db: DbConn; ctx: TaskContext): seq[Rate] =
  ## Tarif golongan pada tanggal buku. Rusak = galat: tarif nol akan menyisihkan nol tanpa jejak,
  ## dan angka PPAP adalah angka laporan keuangan (REG-204 `V!`).
  var value: JsonNode
  try:
    value = activeValueJson(db, keyString(P_lending_ppap_rates), ctx.businessDate,
      lookupFor(institutionScope()))
  except ValueError as e:
    raise abort("DAY-380", "parameter lending.ppap.rates tidak terbaca: " & e.msg)
  let parsed = parsePpapRates(value)
  if not parsed.isOk:
    raise abort("DAY-380", parsed.error.details)
  parsed.val

proc countPpapChunks(pool: DbPool; businessDate: string; chunkSize: int): Result[int, TaskError] =
  ## Jumlah chunk dihitung dari **populasi** pinjaman `ACTIVE`, bukan dari yang sudah ternilai.
  ## Perencanaan chunk terjadi **sebelum** dependensi berjalan (`lending.dpd_regrade`), jadi
  ## prasyarat "semua sudah dinilai" tidak bisa diperiksa di sini — dulu pemeriksaan itu membuat
  ## EOD selalu gagal pada hari pertama ada pinjaman, karena regrading baru jalan sesudah rencana
  ## disusun. Prasyarat itu dipindah ke `runPpapChunk`, saat dependensi sudah selesai.
  ##
  ## Yang tetap diperiksa di sini: penyisihan menggantung (`DAY-384`) — keadaannya tidak bergantung
  ## pada tanggal yang sedang ditutup.
  try:
    let counts = pool.withConn(proc(db: DbConn): tuple[active, stranded: int64] =
      (countActiveLoans(db), strandedAllowances(db)))
    if counts.stranded > 0:
      return err[int, TaskError](taskError("DAY-384",
        $counts.stranded & " pinjaman tidak aktif masih menyimpan penyisihan; aturan pelepasan " &
        "belum ada (D-183 menolak penutupan akad otomatis)"))
    if chunkSize < 1:
      raise newException(ValueError, "chunk size harus >= 1")
    ok[int, TaskError](int((counts.active + int64(chunkSize) - 1) div int64(chunkSize)))
  except IOError as e:
    err[int, TaskError](taskError("DAY-381",
      "jumlah pinjaman berjalan gagal dibaca: " & e.msg, retryable = true))

proc runPpapChunk(pool: DbPool; clock: Clock; ctx: TaskContext; chunk: Chunk): TaskResult =
  ## Satu chunk = satu halaman pinjaman ternilai. Snapshot per pinjaman dan jurnal selisih ditulis
  ## dalam **satu** transaksi: kalau jurnal ditolak, snapshot ikut batal, sehingga
  ## "Δ snapshot == Δ GL" bukan harapan melainkan konsekuensi atomisitas.
  ##
  ## Jurnal dikelompokkan **per cabang**: `ledger.journal_line.branch_id` wajib satu nilai, sedangkan
  ## satu halaman bisa memuat beberapa cabang. Yang dijurnal adalah selisih **neto** per cabang —
  ## itulah perubahan saldo akun penyisihan cabang itu, jadi kenaikan satu pinjaman dan pelepasan
  ## pinjaman lain memang saling menutup di akun yang sama.
  var items: seq[PpapCandidate]
  var rates: seq[Rate]
  try:
    let loaded = pool.withConn(proc(db: DbConn): tuple[items: seq[PpapCandidate]; rates: seq[Rate]] =
      # Prasyarat di sini, bukan saat perencanaan: dependensi (`lending.dpd_regrade`) sudah berjalan
      # ketika chunk dieksekusi. Pinjaman aktif yang belum dinilai akan **dilewati diam-diam** oleh
      # query kandidat, dan itu persis kegagalan yang tidak boleh terjadi pada penyisihan.
      let missing = activeLoansWithoutGrade(db, ctx.businessDate)
      if missing > 0:
        raise abort("DAY-383",
          $missing & " pinjaman ACTIVE belum dinilai kolektibilitasnya untuk " & ctx.businessDate &
          "; jalankan/ulangi lending.dpd_regrade lebih dulu")
      (ppapCandidatesPage(db, ctx.businessDate, chunk.chunkNo * ctx.chunkSize, ctx.chunkSize),
       ppapRates(db, ctx)))
    items = loaded.items
    rates = loaded.rates
  except LendingAbort as e:
    return err[TaskOutcome, TaskError](taskError(e.code, e.msg))
  except IOError as e:
    return err[TaskOutcome, TaskError](taskError("DAY-381",
      "halaman pinjaman ternilai gagal dibaca: " & e.msg, retryable = true))

  var
    written = 0
    skipped = 0
    journals = 0
    provisioned = zero()
    released = zero()
  try:
    discard pool.withTx(proc(db: DbConn): int =
      var
        deltas = initTable[string, Money]()
        branches = initTable[string, Id]()
      for candidate in items:
        let base = moneyFromString(candidate.base)
        if not base.isOk:
          raise abort("DAY-385", "pokok berjalan pinjaman " & $candidate.loanId &
            " bukan nominal sah: " & candidate.base)
        let previous = moneyFromString(candidate.previousAllowance)
        if not previous.isOk:
          raise abort("DAY-385", "penyisihan sebelumnya pinjaman " & $candidate.loanId &
            " bukan nominal sah: " & candidate.previousAllowance)

        let rate = rateFor(rates, candidate.grade)
        let allowance = allowanceFor(base.val, rate)
        if not insertPpapSnapshot(db, candidate.loanId, ctx.businessDate, candidate.grade,
            candidate.base, toDecimalString(allowance), microUnits(rate)):
          # Tanggal itu sudah disisihkan (run ulang): jangan menimpa, jangan menjurnal selisih lagi.
          inc skipped
          continue
        inc written
        let key = $candidate.branchId
        deltas[key] = deltas.getOrDefault(key, zero()) + provisionDelta(previous.val, allowance)
        branches[key] = candidate.branchId

      for key, delta in deltas:
        if delta.isZero:
          # Saldo akun penyisihan cabang itu tidak berubah: jurnal nol bukan jurnal.
          continue
        let eventType = if delta.isPositive: "PpapProvisioned" else: "PpapReleased"
        discard postRuleJournalSync(db, clock, eventType, abs(delta), branches[key],
          Id(ctx.runId), ctx.businessDate,
          "lending.ppap:" & ctx.businessDate & ":" & $chunk.chunkNo & ":" & key, systemActor,
          %*{"businessDate": ctx.businessDate, "chunkNo": chunk.chunkNo}, ctx.runId)
        inc journals
        if delta.isPositive:
          provisioned = provisioned + delta
        else:
          released = released + abs(delta)
      1)
  except LendingAbort as e:
    return err[TaskOutcome, TaskError](taskError(e.code, e.msg))
  except DbError as e:
    return err[TaskOutcome, TaskError](taskError("DAY-382",
      "penyisihan/jurnal ditolak database: " & e.msg, retryable = true))
  except ValueError as e:
    return err[TaskOutcome, TaskError](taskError("DAY-386",
      "konfigurasi jurnal penyisihan tidak sah: " & e.msg))

  if written > 0 or journals > 0:
    try:
      discard pool.withConn(proc(db: DbConn): int =
        let actx = ctlAuditContext(clock, "task " & ppapTaskId)
        discard appendAudit(db, newAuditEntry(actx, "lending.ppap.provision",
          "daycloser_run", ctx.runId, clock, businessDate = ctx.businessDate,
          after = %*{"businessDate": ctx.businessDate, "chunkNo": chunk.chunkNo,
                     "written": written, "skipped": skipped,
                     "provisioned": toDecimalString(provisioned),
                     "released": toDecimalString(released), "journals": journals}))
        1)
    except IOError as e:
      return err[TaskOutcome, TaskError](taskError("DAY-382",
        "audit penyisihan gagal ditulis: " & e.msg, retryable = true))

  ok[TaskOutcome, TaskError](okOutcome(%*{
    "loans": items.len, "written": written, "skipped": skipped, "journals": journals,
    "provisioned": toDecimalString(provisioned), "released": toDecimalString(released),
    "businessDate": ctx.businessDate}))

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
  # PPAP/CKPN (T-167). **Kritis**: task ini menulis jurnal beban penyisihan, jadi kegagalannya
  # harus menahan penutupan buku — angka laporan keuangan tidak boleh ditutup dengan CKPN yang tidak
  # cocok dengan snapshot. `dependsOn` membuat "golongan hari ini sudah dinilai" menjadi kontrak
  # registry, bukan kebetulan urutan pendaftaran.
  reg.register DayCloseTask(
    id: ppapTaskId,
    module: "lending",
    levels: {clEOD},
    kind: tkProcess,
    dependsOn: @[regradeTaskId],
    critical: true,
    idempotency: imPerBusinessDate,
    partition: psByChunkCount,
    requiredParams: @["lending.ppap.rates"],
    countChunks: proc(ctx: TaskContext; chunkSize: int): Result[int, TaskError] =
    countPpapChunks(pool, ctx.businessDate, chunkSize),
    run: proc(ctx: TaskContext; chunk: Chunk): TaskResult =
    runPpapChunk(pool, clock, ctx, chunk))
