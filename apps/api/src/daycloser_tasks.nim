## Registrasi task day-close untuk proses `ctl` (spec §11.4, §11.6).
##
## Dipisah dari `daycloser_ctl.nim` supaya berkas perintah tidak merangkap sebagai katalog task:
## composition root tetap satu (pool + clock), sedangkan daftar pekerjaan tumbuh setiap fase
## (gate T-136, ledger T-137, deposit T-138).
##
## Aturan yang dipegang: task baru **didaftarkan di sini**, tidak pernah dengan membuat batch/cron
## sendiri di modulnya (AGENTS.md §1.7). Salinan tabel `daycloser.task_registry` diperbarui oleh
## `syncRegistry` dan hanya untuk modul yang benar-benar didaftarkan proses ini.

import std/[json, strutils]

import db_connector/db_postgres

import "platform-lib/db/pool"

import kernel/[dayclose, paramkey, result]
import kernel/generated/paramkeys

import platform/api

import daycloser/domain/[registry, types]
import daycloser/infrastructure/run_repo

import ./daycloser_deposit
import ./daycloser_lending
import ./daycloser_gates
import ./daycloser_ledger

const
  ## Task pertama yang terdaftar: menyapu klaim idempotensi kedaluwarsa (T-089, D-098).
  idempotencySweepTaskId = "platform.idempotency_sweep"
  ## Retensi outbox/inbox (T-282, D-206). Dua task terpisah, bukan satu, karena nilai retensinya
  ## dua parameter berbeda dan kegagalan satu tabel tidak boleh menyembunyikan yang lain.
  outboxPurgeTaskId = "platform.outbox_purge"
  inboxPurgeTaskId = "platform.inbox_purge"

proc retentionDaysFor(pool: DbPool; ctx: TaskContext; key, code: string): Result[int, TaskError] =
  ## Ambang retensi (hari) pada tanggal buku. Parameter hilang atau bukan bilangan positif =
  ## kesalahan konfigurasi (`code`), bukan "lewati saja" dan bukan "hapus semuanya": nilai yang
  ## tidak terbaca tidak boleh diterjemahkan menjadi interval yang lebih pendek dari kebijakan.
  try:
    ok[int, TaskError](pool.withConn(proc(db: DbConn): int =
      retentionDays(db, key, ctx.businessDate)))
  except ValueError as e:
    err[int, TaskError](taskError(code, e.msg))
  except DbError as e:
    err[int, TaskError](taskError(code, "parameter " & key & " gagal dibaca: " & e.msg,
      retryable = true))

proc outboxPurgeTask*(pool: DbPool): DayCloseTask =
  ## Retensi outbox (T-282, D-206, spec §5.6). Tidak kritis: memangkas riwayat yang sudah
  ## kedaluwarsa tidak memindahkan uang, jadi kegagalannya dicatat `FAILED` dan bisa diulang tanpa
  ## menahan penutupan buku. Hapus bertahap per `chunkSize`, sama seperti sapu idempotensi, supaya
  ## tabel besar tidak ditahan satu transaksi panjang.
  DayCloseTask(
    id: outboxPurgeTaskId,
    module: "platform",
    levels: {clEOD},
    kind: tkProcess,
    dependsOn: @[],
    critical: false,
    idempotency: imPerBusinessDate,
    partition: psSingle,
    requiredParams: @[keyString(P_platform_outbox_retention_days)],
    run: proc(ctx: TaskContext; chunk: Chunk): TaskResult =
    let batch = max(1, ctx.chunkSize)
    let days = retentionDaysFor(pool, ctx, keyString(P_platform_outbox_retention_days),
      "DAY-402")
    if days.isErr:
      return err[TaskOutcome, TaskError](days.error)
    var total = 0
    try:
      while true:
        let deleted = pool.withConn(proc(db: DbConn): int =
          purgeOutbox(db, days.value, batch))
        total += deleted
        if deleted < batch:
          break
    except DbError as e:
      return err[TaskOutcome, TaskError](taskError(
        "DAY-403", "purge outbox gagal: " & e.msg, retryable = true))
    ok[TaskOutcome, TaskError](okOutcome(%*{
      "deleted": total, "retentionDays": days.value})))

proc inboxPurgeTask*(pool: DbPool): DayCloseTask =
  ## Retensi inbox (T-282, D-206, spec §5.6). Dua task terpisah, bukan satu, karena nilai
  ## retensinya dua parameter berbeda dan kegagalan satu tabel tidak boleh menyembunyikan yang lain.
  DayCloseTask(
    id: inboxPurgeTaskId,
    module: "platform",
    levels: {clEOD},
    kind: tkProcess,
    dependsOn: @[],
    critical: false,
    idempotency: imPerBusinessDate,
    partition: psSingle,
    requiredParams: @[keyString(P_platform_inbox_retention_days)],
    run: proc(ctx: TaskContext; chunk: Chunk): TaskResult =
    let batch = max(1, ctx.chunkSize)
    let days = retentionDaysFor(pool, ctx, keyString(P_platform_inbox_retention_days),
      "DAY-404")
    if days.isErr:
      return err[TaskOutcome, TaskError](days.error)
    var total = 0
    try:
      while true:
        let deleted = pool.withConn(proc(db: DbConn): int =
          purgeInbox(db, days.value, batch))
        total += deleted
        if deleted < batch:
          break
    except DbError as e:
      return err[TaskOutcome, TaskError](taskError(
        "DAY-405", "purge inbox gagal: " & e.msg, retryable = true))
    ok[TaskOutcome, TaskError](okOutcome(%*{
      "deleted": total, "retentionDays": days.value})))

proc registerDayCloseTasks*(reg: Registry; pool: DbPool) =
  ## Registry nyata saat boot `ctl`. Task bisnis dari fase berikutnya ditambahkan di sini.
  reg.register DayCloseTask(
    id: idempotencySweepTaskId,
    module: "platform",
    levels: {clEOD},
    kind: tkProcess,
    dependsOn: @[],
    critical: false,
    idempotency: imPerBusinessDate,
    partition: psSingle,
    requiredParams: @["platform.idempotency.ttl_hours"],
    run: proc(ctx: TaskContext; chunk: Chunk): TaskResult =
    ## Hapus bertahap: satu perintah menghapus paling banyak `chunkSize` baris, jadi tabel
    ## besar tidak menahan satu transaksi panjang. Baris kedaluwarsa tidak pernah dibaca lagi
    ## (klaim hanya melihat `expires_at > now()`), sehingga menghapusnya tidak mengubah replay
    ## yang sah.
    var total = 0
    let batch = max(1, ctx.chunkSize)
    try:
      while true:
        let deleted = pool.withConn(proc(db: DbConn): int =
          db.execAffectedRows(sql"""
              WITH doomed AS (
                SELECT principal_id, key
                  FROM platform.idempotency_key
                 WHERE expires_at <= now()
                 ORDER BY expires_at
                 LIMIT ?)
              DELETE FROM platform.idempotency_key k
               USING doomed d
               WHERE k.principal_id = d.principal_id AND k.key = d.key""", batch))
        total += deleted
        if deleted < batch:
          break
    except DbError as e:
      return err[TaskOutcome, TaskError](taskError(
        "DAY-201", "sapu idempotensi gagal: " & e.msg, retryable = true))
    ok[TaskOutcome, TaskError](okOutcome(%*{"deleted": total})))

  reg.register outboxPurgeTask(pool)
  reg.register inboxPurgeTask(pool)

  # Gate pra & pasca-tutup (spec §11.5 langkah 2 & 5). Kritis: gagal = run BLOCKED.
  registerGates(reg, pool)

  # Akrual bunga deposito (T-138c) dan jatuh tempo/ARO (T-138d). Urutan eksekusi satu fase
  # **bukan** urutan registrasi: registry mengurutkan topologis dengan tie-break alfabetis
  # (`daycloser/domain/registry.nim`), jadi `deposit.*` kebetulan berjalan sebelum `ledger.*`
  # karena id-nya, sedangkan urutan **antar** task deposit hanya dijamin `dependsOn` (lihat
  # `registerDepositTasks`). Snapshot saldo harian sebaiknya melihat jurnal akrual hari itu,
  # bukan jurnal kemarin.
  registerDepositTasks(reg, pool)

  # Kolektibilitas pinjaman (T-166). Tidak bergantung pada task deposit/ledger: DPD dihitung dari
  # jadwal angsuran, bukan dari saldo. Tidak kritis — penilaian golongan tidak memindahkan uang.
  registerLendingTasks(reg, pool)

  # Pekerjaan buku besar (spec §11.6): snapshot saldo harian + tutup periode GL bulanan (T-137).
  registerLedgerTasks(reg, pool)

proc syncRegistry*(pool: DbPool; reg: Registry) =
  ## Registry in-process adalah sumber kebenaran eksekusi; tabel hanya salinan untuk UI/audit.
  ## Baris yang task-nya sudah tidak terdaftar **dihapus**: salinan yang menyebut task hantu lebih
  ## buruk daripada tidak ada salinan, karena UI akan menawarkan pekerjaan yang tidak bisa jalan.
  var ids, modules: seq[string]
  for task in reg.all():
    ids.add task.id
    if task.module notin modules:
      modules.add task.module
  discard pool.withTx(proc(db: DbConn): int =
    for task in reg.all():
      db.upsertRegistry(task)
    # Hanya modul yang didaftarkan proses ini yang dipangkas: composition root lain (worker,
    # ctl modul lain, test) boleh mendaftarkan subset dan tidak boleh menghapus baris modul lain.
    if ids.len > 0:
      discard db.execAffectedRows(sql"""
        DELETE FROM daycloser.task_registry
         WHERE module = ANY(?::text[]) AND task_id <> ALL(?::text[])""",
        textArray(modules.join(",")), textArray(ids.join(",")))
    1)
