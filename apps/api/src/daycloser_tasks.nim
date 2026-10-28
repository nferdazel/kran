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

import kernel/[dayclose, result]

import daycloser/domain/[registry, types]
import daycloser/infrastructure/run_repo

import ./daycloser_deposit
import ./daycloser_gates
import ./daycloser_ledger

const
  ## Task pertama yang terdaftar: menyapu klaim idempotensi kedaluwarsa (T-089, D-098).
  idempotencySweepTaskId = "platform.idempotency_sweep"

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

  # Gate pra & pasca-tutup (spec §11.5 langkah 2 & 5). Kritis: gagal = run BLOCKED.
  registerGates(reg, pool)

  # Akrual bunga deposito (T-138c). Didaftarkan **sebelum** pekerjaan buku besar: urutan registrasi
  # adalah urutan eksekusi dalam satu fase, dan snapshot saldo harian sebaiknya melihat jurnal
  # akrual hari itu, bukan jurnal kemarin.
  registerDepositTasks(reg, pool)

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
