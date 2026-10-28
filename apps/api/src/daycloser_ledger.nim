## Task `ledger` untuk kerangka day-close (T-137, spec §11.6 "Snapshot saldo & TB harian",
## "Tutup periode GL").
##
## Dua pekerjaan, dua tingkat:
##   - `ledger.daily_snapshot` (EOD, fase proses): menulis ulang cache `ledger.balance_snapshot`
##     untuk tanggal buku dan **membuktikan** cache itu sama dengan jurnal — snapshot yang tidak
##     cocok adalah bukti palsu, lebih buruk daripada tidak ada.
##   - `ledger.period_close` (EOM, fase pasca-tutup): menutup periode GL yang jatuh tempo pada
##     tanggal buku, memakai jalur `closePeriod` yang sama dengan HTTP (audit + event
##     `period.closed` dalam satu transaksi).
##
## Keduanya idempoten per business date: menjalankan ulang tanggal yang sama menghasilkan keadaan
## yang sama (snapshot dibangun ulang; periode yang sudah CLOSED dilaporkan, bukan digagalkan).

import std/[json, options, strutils]

import db_connector/db_postgres

import nimcrypto/[sha2, utils]

import "platform-lib/db/pool"

import kernel/[clock, dayclose, ids, money, result]

import platform/domain/[audit, event]
import platform/infrastructure/[audit_repo, outbox_repo]

import ledger/domain/[period, report]
import ledger/infrastructure/[ledger_repo, report_repo]

import daycloser/domain/[registry, types]

import teller/infrastructure/session_repo

import ./daycloser_common

const
  snapshotTaskId* = "ledger.daily_snapshot"
  periodCloseTaskId* = "ledger.period_close"

  ## Jumlah akun yang ikut disimpan sebagai bukti saat snapshot tidak cocok. Cukup untuk menunjuk
  ## masalah, tidak sampai membengkakkan `task.metrics`.
  evidenceLimit = 20

type
  SnapshotAbort = object of CatchableError
    ## Dibatalkan **dari dalam** transaksi supaya rebuild snapshot di-rollback: cache yang salah
    ## tidak boleh tertinggal hanya karena pemeriksaannya gagal setelah penulisan.
    code*: string

proc snapshotHash(lines: seq[SnapshotTotal]): string =
  ## Sidik jari isi snapshot. Dipakai sebagai bukti yang bisa dibandingkan antar run tanpa
  ## menyimpan seluruh tabel di metrics: dua run yang menghasilkan angka berbeda pasti berbeda
  ## hash-nya.
  var parts: seq[string]
  for l in lines:
    parts.add l.accountCode & "|" & l.debit.toDecimalString & "|" & l.credit.toDecimalString
  var ctx: sha256
  ctx.init()
  ctx.update(join(parts, "\n"))
  let digest = ctx.finish()
  result = utils.toHex(digest.data, lowercase = true)
  ctx.clear()

proc sameMonth(a, b: string): bool =
  ## Tanggal ISO (`YYYY-MM-DD`) di bulan kalender yang sama. Dipakai untuk memutuskan apakah
  ## periode itu **jatuh tempo** pada penutupan bulanan ini.
  a.len >= 7 and b.len >= 7 and a[0 .. 6] == b[0 .. 6]

proc abortSnapshot(code, message: string): ref SnapshotAbort =
  result = newException(SnapshotAbort, message)
  result.code = code

proc registerLedgerTasks*(reg: Registry; pool: DbPool) =
  let clock = systemClock()

  reg.register DayCloseTask(
    id: snapshotTaskId,
    module: "ledger",
    levels: {clEOD},
    kind: tkProcess,
    dependsOn: @[],
    critical: true,
    idempotency: imPerBusinessDate,
    partition: psSingle,
    requiredParams: @[],
    run: proc(ctx: TaskContext; chunk: Chunk): TaskResult =
    ## Tulis ulang snapshot, bandingkan dengan jurnal, dan **batalkan transaksi bila tidak
    ## cocok**. `rebuildSnapshot` melakukan DELETE+INSERT untuk `as_of` itu, jadi run ulang tidak
    ## menggandakan baris.
    var metrics: JsonNode = nil
    try:
      discard pool.withTx(proc(d: DbConn): int =
        rebuildSnapshot(d, ctx.businessDate)
        let lines = balancesFromLedger(d, earliestDate, ctx.businessDate)
        let cached = snapshotBalances(d, ctx.businessDate)

        var debit = zero()
        var credit = zero()
        for l in lines:
          debit = debit + l.closingDebit
          credit = credit + l.closingCredit

        metrics = %*{"asOf": ctx.businessDate, "accounts": cached.len,
                     "ledgerAccounts": lines.len,
                     "totalDebit": debit.toDecimalString,
                     "totalCredit": credit.toDecimalString,
                     "snapshotHash": snapshotHash(cached)}

        # Bukti harus cocok dengan sumbernya. Perbandingan memakai `snapshotMatches` (domain) —
        # aturan yang sama dengan laporan yang membuktikan saldo lewat cache. Melempar dari dalam
        # transaksi membuat cache yang salah tidak pernah ter-commit.
        if not snapshotMatches(lines, cached):
          metrics["accountDiff"] = %snapshotDiff(lines, cached, evidenceLimit)
          raise abortSnapshot("DAY-321",
            "snapshot saldo tidak sama dengan jurnal untuk " & ctx.businessDate)
        if debit != credit:
          raise abortSnapshot("DAY-322",
            "trial balance tidak seimbang saat snapshot " & ctx.businessDate)
        1)
    except SnapshotAbort as e:
      return err[TaskOutcome, TaskError](taskError(e.code, e.msg, metrics = metrics))
    except IOError as e:
      return err[TaskOutcome, TaskError](taskError(
        "DAY-320", "snapshot saldo gagal ditulis: " & e.msg, retryable = true))

    ok[TaskOutcome, TaskError](okOutcome(metrics)))

  reg.register DayCloseTask(
    id: periodCloseTaskId,
    module: "ledger",
    levels: {clEOM},
    # Pasca-tutup, bukan proses: penutupan periode **tidak bisa dibatalkan** (trigger periode),
      # jadi ia harus berjalan setelah seluruh task proses lain dan setelah gate pasca-tutup lulus.
      # Menutup lebih awal akan menolak jurnal akrual/pajak yang berjalan sesudahnya, dan bila gate
      # kemudian gagal tidak ada cara memperbaiki bulan itu.
    kind: tkPostCheck,
    dependsOn: @[snapshotTaskId, "ledger.no_late_postings", "ledger.subledger_vs_gl",
      "ledger.trial_balance"],
    critical: true,
    idempotency: imPerBusinessDate,
    partition: psSingle,
    requiredParams: @[],
    run: proc(ctx: TaskContext; chunk: Chunk): TaskResult =
      var found: Option[Period]
      var earlier: Option[Period]
      try:
        discard pool.withConn(proc(d: DbConn): int =
          found = periodContaining(d, ctx.businessDate)
          if found.isSome:
            earlier = earlierOpenPeriod(d, found.get.startsOn)
          1)
      except IOError as e:
        return err[TaskOutcome, TaskError](taskError(
          "DAY-323", "periode GL tidak terbaca: " & e.msg, retryable = true))

      if found.isNone:
        # Tidak ada periode yang memuat tanggal ini sama sekali: buku besar tidak punya dasar untuk
        # hari itu (jurnal pun akan ditolak trigger). Itu konfigurasi yang hilang, bukan "tidak
        # berlaku", jadi penutupan berhenti dan operator membuat periodenya.
        return err[TaskOutcome, TaskError](taskError(
          "DAY-324", "tidak ada periode GL yang memuat " & ctx.businessDate &
          "; buat periodenya lebih dulu",
          metrics = %*{"businessDate": ctx.businessDate}))

      let p = found.get
      let base = %*{"periodId": $p.periodId, "startsOn": p.startsOn, "endsOn": p.endsOn}
      if not sameMonth(p.endsOn, ctx.businessDate):
        # Periode lebih panjang dari sebulan (mis. periode tahunan): tidak ada yang jatuh tempo
        # pada penutupan bulan ini. Ini "tidak berlaku", bukan kegagalan — institusi yang memakai
        # periode tahunan tetap bisa menutup bulan tanpanya.
        var metrics = base
        metrics["status"] = %"NOT_DUE"
        return ok[TaskOutcome, TaskError](okOutcome(metrics))

      if p.status == psClosed:
        var metrics = base
        metrics["status"] = %"CLOSED"
        metrics["alreadyClosed"] = %true
        return ok[TaskOutcome, TaskError](okOutcome(metrics))

      if earlier.isSome:
        return err[TaskOutcome, TaskError](taskError(
          "DAY-328", "periode " & earlier.get.startsOn & ".." & earlier.get.endsOn &
          " masih OPEN; tutup periode secara berurutan", metrics = base))

      var closedAt = ""
      var openSessions: int64
      let actx = ctlAuditContext(clock, "tutup periode GL (day-close)")
      try:
        closedAt = pool.withTx(proc(d: DbConn): string =
          # Cermin dari handler `POST /ledger/periods/{id}/close`: sesi kas OPEN di rentang
          # periode membuat penutupan menjebak (jurnal tutup sesi ditolak trigger periode, dan
          # tidak ada jalur reopen).
          openSessions = openSessionCount(d, p.startsOn, p.endsOn)
          if openSessions > 0:
            return ""
          let at = closePeriodSystem(d, p.periodId)
          if at.len == 0:
            return ""
          discard appendAudit(d, newAuditEntry(actx, "ledger.period.close", "period",
            $p.periodId, clock, businessDate = ctx.businessDate,
            after = %*{"periodId": $p.periodId, "status": "CLOSED",
                       "startsOn": p.startsOn, "endsOn": p.endsOn}))
          discard appendEvent(d, newOutboxEvent(newId(clock), "period.closed", "period",
            $p.periodId, "period.closed:" & $p.periodId,
            %*{"periodId": $p.periodId, "startsOn": p.startsOn, "endsOn": p.endsOn}))
          at)
      except IOError as e:
        return err[TaskOutcome, TaskError](taskError(
          "DAY-325", "penutupan periode gagal: " & e.msg, retryable = true))

      var metrics = base
      metrics["status"] = %(if closedAt.len > 0: "CLOSED" else: $p.status)
      metrics["openSessions"] = %openSessions
      metrics["closedAt"] = %closedAt
      if openSessions > 0:
        return err[TaskOutcome, TaskError](taskError(
          "DAY-326", $openSessions & " sesi kas OPEN pada rentang periode " & p.startsOn &
          ".." & p.endsOn & "; batalkan penutupan, tutup sesinya, lalu ulangi",
          metrics = metrics))
      if closedAt.len == 0:
        return err[TaskOutcome, TaskError](taskError(
          "DAY-327", "periode " & p.startsOn & ".." & p.endsOn &
          " tidak bisa ditutup (status berubah di tengah?)", metrics = metrics))
      ok[TaskOutcome, TaskError](okOutcome(metrics)))
