## Orkestrator day-close (lapisan application) — logika murni di atas port `Store`.
##
## Lapisan ini **tidak** menyentuh DB/driver: semua persistence lewat port yang diisi composition
## root. Dengan begitu urutan state, retry, dan aturan kritis bisa diuji tanpa Postgres, dan
## implementasi penyimpanan bisa diganti (mis. simulation di transaksi ter-rollback) tanpa
## mengubah alur.
##
## Yang dijalankan orkestrator (spec §11.5):
##   PRECHECK → **freeze** (business date `CLOSING`) → RUNNING (process/report) → POSTCHECK →
##   **seal** (run `COMPLETED`, tanggal `CLOSED`, rollover ke hari kerja berikutnya, event
##   `BusinessDateOpened`). Pembatalan membuka kembali tanggal yang dibekukan run itu.

import std/[json, sets, strutils]

import nimcrypto/[sha2, utils]

import kernel/[dayclose, result]

import ../domain/[registry, run, state, types]

type
  Store* = object
    ## Port persistence. Prosedur boleh melempar exception untuk kegagalan infrastruktur
    ## (DB mati) — itu bukan alur normal, dan `ctl` memetakannya ke kode keluar 1.
    createRun*: proc(runId: string; req: RunRequest; plan: seq[PlannedTask]) {.closure.}
    snapshot*: proc(runId: string): RunSnapshot {.closure.}
    setRunState*: proc(runId: string; st: RunState; at: string;
                        summaryHash: string) {.closure.}
    freezeDate*: proc(runId: string) {.closure.}
      ## `OPEN → CLOSING` untuk tanggal run (spec §11.5 #3). Idempoten bila tanggal itu sudah
      ## `CLOSING` — resume setelah crash tidak boleh gagal hanya karena freeze sudah terjadi.
    sealRun*: proc(runId: string; at, summaryHash: string) {.closure.}
      ## Transisi terakhir **dan** segel tanggal dalam satu transaksi (composition root):
      ## `RUN → COMPLETED`, audit `run.finish`, `CLOSING → CLOSED`, rollover ke hari kerja
      ## berikutnya, dan event `BusinessDateOpened`. Dipisah dari `setRunState` supaya run yang
      ## tersegel tidak bisa ada tanpa tanggal yang ikut maju (dan sebaliknya).
    cancelRun*: proc(runId, at: string) {.closure.}
      ## Pembatalan **atomik**: sisa task `CANCELED`, run `CANCELED`, dan tanggal buku yang
      ## dibekukan run itu dibuka kembali (`CLOSING → OPEN`) dalam satu transaksi.
      ## Dipisah dari tiga port terpisah karena urutan yang setengah jadi meninggalkan
      ## `CANCELED` + `CLOSING` — keadaan yang menahan semua tulisan tanpa perintah pemulih.
    setTaskState*: proc(runId: string; taskId: TaskId; st: TaskState; at: string;
                        err, metrics: JsonNode) {.closure.}
    setChunkState*: proc(runId: string; taskId: TaskId; chunkNo: int; st: ChunkState;
                         at: string; err: JsonNode) {.closure.}
    controlOf*: proc(runId: string): RunControl {.closure.}
    setControl*: proc(runId: string; control: RunControl) {.closure.}
    resetInFlight*: proc(runId: string) {.closure.}

  Now* = proc(): string {.closure.} ## waktu ISO-8601 UTC
  Sleeper* = proc(ms: int) {.closure.} ## diuji dengan no-op
  Logger* = proc(line: string) {.closure.}

proc errorJson(e: TaskError): JsonNode =
  %*{"code": e.code, "message": e.message, "retryable": e.retryable}

proc phaseOf*(kind: TaskKind): RunState =
  ## `REPORT` berjalan bersama proses: laporan membaca data yang sudah diposting hari itu dan
  ## tidak boleh menahan penutupan lebih lama dari prosesnya sendiri.
  case kind
  of tkPreCheck: rsPrecheck
  of tkProcess, tkReport: rsRunning
  of tkPostCheck: rsPostcheck

proc summaryOf(snap: RunSnapshot): string =
  ## Hash ringkasan run (spec §11.5 "seal", tamper-evident). Isinya **hanya** fakta yang
  ## menentukan hasil: state & attempt tiap task. Kegagalan task ikut karena mengubah arti run.
  var parts: seq[string]
  parts.add snap.runId
  parts.add snap.businessDate
  parts.add levelsCsv(snap.levels)
  parts.add $snap.mode
  for t in snap.tasks:
    parts.add t.taskId & ":" & $t.state & ":" & $t.attempt
  var ctx: sha256
  ctx.init()
  ctx.update(join(parts, "|"))
  let digest = ctx.finish()
  result = utils.toHex(digest.data, lowercase = true)
  ctx.clear()

proc cancelRun(store: Store; runId, at: string) =
  ## Satu jalur pembatalan untuk dua titik (batas fase dan batas chunk). Ketiga tulisan (task,
  ## run, tanggal) ada di **satu** transaksi milik port `cancelRun`: tanpa itu, crash di antaranya
  ## meninggalkan `CANCELED` + `CLOSING` yang menolak semua tulisan dan tidak bisa diperbaiki
  ## perintah mana pun.
  store.cancelRun(runId, at)

proc applyControl(store: Store; runId: string; current: RunState; at: string): RunState =
  ## Baca permintaan operator **di batas chunk** (spec §11.7). Hanya state yang sedang berjalan
  ## yang bisa dipause/dibatalkan; permintaan basi pada run yang sudah selesai diabaikan.
  case store.controlOf(runId)
  of rcNone:
    current
  of rcPause:
    if current in {rsPrecheck, rsRunning, rsPostcheck}:
      store.setRunState(runId, rsPaused, at, "")
      rsPaused
    else:
      current
  of rcCancel:
    if current in {rsPrecheck, rsRunning, rsPostcheck}:
      cancelRun(store, runId, at)
      rsCanceled
    else:
      current

type
  TaskRunResult = object
    state: TaskState
    err: TaskError
    metrics: JsonNode
    reason: string
    stop: RunControl ## PAUSE/CANCEL diminta operator di batas chunk

proc runTask(store: Store; task: DayCloseTask; ctx: TaskContext; progress: TaskProgress;
             cfg: Config; runId: string; now: Now; sleepMs: Sleeper;
             log: Logger): TaskRunResult =
  ## Menjalankan satu task chunk demi chunk. Chunk yang sudah `SUCCEEDED` dilewati, jadi resume
  ## tidak mengulang pekerjaan yang sudah selesai (spec §11.7 "Resume & Retry").
  var lastMetrics: JsonNode = nil
  for ch in progress.chunks:
    if ch.state == csSucceeded:
      continue
    var attempt = ch.attempt
    var settled = false
    while not settled:
      # Pause/cancel dibaca **di batas chunk/percobaan**, bukan hanya antar-task: task besar
      # (mis. snapshot 100k rekening) harus bisa dihentikan tanpa menunggu selesai (spec §11.7).
      let ctrl = store.controlOf(runId)
      if ctrl != rcNone:
        return TaskRunResult(state: tsPending, stop: ctrl, metrics: lastMetrics)
      inc attempt
      store.setChunkState(runId, task.id, ch.chunkNo, csRunning, now(), nil)
      log("  " & task.id & " chunk " & $ch.chunkNo & " percobaan " & $attempt)
      let res = task.run(ctx, Chunk(chunkNo: ch.chunkNo))
      if res.isOk:
        let outcome = res.value
        if not outcome.metrics.isNil:
          lastMetrics = outcome.metrics
        if outcome.skipped:
          # "Skip by rule" hanya sah untuk task non-kritis satu-chunk. Chunk **tidak** ditandai
          # SUCCEEDED pada kasus yang ditolak: kalau ditandai, resume akan menganggap task
          # selesai tanpa pernah menjalankannya (review T-134 #2).
          var refusal: TaskError
          if progress.chunks.len > 1:
            refusal = taskError("DAY-104",
              "task multi-chunk " & task.id & " meminta skip di tengah")
          elif task.critical:
            refusal = taskError("DAY-105",
              "task kritis " & task.id & " meminta skip: " & outcome.reason)
          if refusal.code.len > 0:
            store.setChunkState(runId, task.id, ch.chunkNo, csPending, now(),
              errorJson(refusal))
            return TaskRunResult(state: tsFailed, err: refusal, metrics: lastMetrics,
                                 reason: outcome.reason)
          store.setChunkState(runId, task.id, ch.chunkNo, csSucceeded, now(), nil)
          return TaskRunResult(state: tsSkipped, reason: outcome.reason,
                               metrics: lastMetrics)
        store.setChunkState(runId, task.id, ch.chunkNo, csSucceeded, now(), nil)
        settled = true
      else:
        let e = res.error
        let willRetry = e.retryable and attempt < cfg.maxAttempts
        # Chunk kembali PENDING sebelum dicoba lagi supaya status yang terbaca operator tidak
        # pernah berbohong "RUNNING" di antara dua percobaan.
        store.setChunkState(runId, task.id, ch.chunkNo,
          (if willRetry: csPending else: csFailed), now(), errorJson(e))
        if not willRetry:
          return TaskRunResult(state: tsFailed, err: e, metrics: lastMetrics)
        log("  " & task.id & " chunk " & $ch.chunkNo & " gagal (" & e.code &
            "), ulang dalam " & $cfg.retryBackoffSeconds & "s")
        sleepMs(cfg.retryBackoffSeconds * 1000)

  if not task.verify.isNil:
    var vattempt = 0
    while true:
      inc vattempt
      let v = task.verify(ctx)
      if v.isOk:
        break
      let e = v.error
      if e.retryable and vattempt < cfg.maxAttempts:
        log("  " & task.id & " verifikasi gagal (" & e.code & "), ulang")
        sleepMs(cfg.retryBackoffSeconds * 1000)
        continue
      return TaskRunResult(state: tsFailed, err: e, metrics: lastMetrics)

  TaskRunResult(state: tsSucceeded, metrics: lastMetrics)

proc countsOf(snap: RunSnapshot): tuple[ok, failed, skipped: int] =
  for t in snap.tasks:
    case t.state
    of tsSucceeded: inc result.ok
    of tsFailed: inc result.failed
    of tsSkipped: inc result.skipped
    else: discard

proc outcomeOf(store: Store; runId: string; state: RunState;
               summaryHash = ""): RunOutcome =
  ## Angka pada `RunOutcome` selalu dibaca ulang dari DB, bukan dihitung dari variabel lokal yang
  ## mungkin tertinggal — audit `run.finish` untuk run gagal harus menyebut jumlah yang benar.
  let c = countsOf(store.snapshot(runId))
  RunOutcome(state: state, summaryHash: summaryHash,
             succeeded: c.ok, failed: c.failed, skipped: c.skipped)

proc validatedTasks(registry: Registry; snap: RunSnapshot): seq[DayCloseTask] =
  ## Rencana chunk dibekukan, tetapi daftar task dihitung ulang dari registry hidup. Bila
  ## registry berubah sejak run dibuat (deploy baru saat run FAILED), melanjutkan akan melewatkan
  ## task baru atau meninggalkan task yang sudah tidak dikenal sebagai PENDING selamanya.
  ## Divalidasi **sebelum** state run disentuh, supaya penolakan tidak meninggalkan run setengah
  ## berubah.
  result = registry.resolve(snap.levels)
  var registryIds = initHashSet[TaskId]()
  var snapshotIds = initHashSet[TaskId]()
  for t in result:
    registryIds.incl t.id
  for t in snap.tasks:
    snapshotIds.incl t.taskId
  if registryIds != snapshotIds:
    raise newException(DayCloserError,
      "registry task berubah sejak run " & snap.runId & " dibuat (registry " &
      $registryIds.len & " task, run " & $snapshotIds.len &
      " task); selesaikan/batalkan run lama sebelum mengganti registry")
  for t in result:
    let p = snap.taskProgress(t.id)
    if p.kind != t.kind or p.critical != t.critical:
      raise newException(DayCloserError,
        "definisi task " & t.id & " berubah sejak run " & snap.runId &
        " dibuat (kind/critical); batalkan run lama atau kembalikan kode")

proc executeRun*(registry: Registry; store: Store; runId: string;
                 now: Now; sleepMs: Sleeper; log: Logger): RunOutcome =
  ## Melanjutkan run dari state-nya sekarang. Fase yang task-nya sudah selesai akan dilewati;
  ## ini jalur yang sama untuk start dan resume, jadi tidak ada dua implementasi yang bisa
  ## menyimpang.
  var snap = store.snapshot(runId)
  if snap.state in {rsCompleted, rsCanceled}:
    raise newException(DayCloserError,
      "run " & runId & " sudah berakhir (" & $snap.state & ")")
  let tasks = validatedTasks(registry, snap)
  if snap.state == rsPlanned:
    store.setRunState(runId, rsPrecheck, now(), "")
    snap.state = rsPrecheck

  let ctx = TaskContext(runId: runId, scopeType: snap.scopeType, scopeId: snap.scopeId,
                        businessDate: snap.businessDate, levels: snap.levels, mode: snap.mode,
                        chunkSize: snap.config.chunkSize)

  var state = snap.state
  if state notin {rsPlanned, rsPrecheck}:
    # Satu jalur masuk: start (PLANNED) atau `resumeRun` (yang menormalkan state ke PRECHECK).
    # Menerima RUNNING/POSTCHECK di sini akan melewati fase yang mungkin belum selesai.
    raise newException(DayCloserError,
      "executeRun dipanggil pada state " & $state & "; gunakan resumeRun")
  for phase in [rsPrecheck, rsRunning, rsPostcheck]:
    if phase == rsRunning and state == rsPrecheck:
      # Spec §11.5 #3: gate pra-tutup lulus → bekukan tanggal buku, baru jalankan task. Freeze
      # adalah bagian dari run, bukan langkah operator terpisah: task yang memposting tidak boleh
      # berjalan sementara transaksi daring masih diterima.
      try:
        store.freezeDate(runId)
        log("tanggal buku " & snap.businessDate & " → CLOSING")
      except DayCloserError as e:
        store.setRunState(runId, rsFailed, now(), "")
        log("run " & runId & " GAGAL membekukan tanggal buku: " & e.msg)
        return outcomeOf(store, runId, rsFailed)
    if state != phase:
      if not canTransition(state, phase):
        raise newException(DayCloserError,
          "transisi run tidak sah: " & $state & " -> " & $phase)
      store.setRunState(runId, phase, now(), "")
      state = phase
    state = applyControl(store, runId, state, now())
    if state in {rsPaused, rsCanceled}:
      return outcomeOf(store, runId, state)

    for task in tasks:
      if phaseOf(task.kind) != phase:
        continue
      let progress = snap.taskProgress(task.id)
      if progress.state in {tsSucceeded, tsSkipped, tsCanceled}:
        continue
      state = applyControl(store, runId, state, now())
      if state in {rsPaused, rsCanceled}:
        return outcomeOf(store, runId, state)

      store.setTaskState(runId, task.id, tsReady, now(), nil, nil)
      store.setTaskState(runId, task.id, tsRunning, now(), nil, nil)
      log(task.id & " mulai (" & $task.kind & ")")
      let r = runTask(store, task, ctx, progress, snap.config, runId, now, sleepMs, log)
      if r.stop != rcNone:
        # Task dikembalikan ke PENDING supaya status jujur: tidak ada pekerjaan yang sedang
        # berjalan saat operator meminta berhenti.
        store.setTaskState(runId, task.id, tsPending, now(), nil, nil)
        if r.stop == rcCancel:
          cancelRun(store, runId, now())
          log("run " & runId & " dibatalkan operator di batas chunk")
          return outcomeOf(store, runId, rsCanceled)
        store.setRunState(runId, rsPaused, now(), "")
        log("run " & runId & " dipause operator di batas chunk")
        return outcomeOf(store, runId, rsPaused)
      store.setTaskState(runId, task.id, r.state, now(),
        (if r.state == tsFailed: errorJson(r.err) else: nil), r.metrics)
      log(task.id & " → " & $r.state &
          (if r.state == tsSkipped: " (" & r.reason & ")" else: ""))

      if r.state == tsFailed:
        if task.critical:
          store.setRunState(runId, rsFailed, now(), "")
          log("run " & runId & " GAGAL: task kritis " & task.id & " (" & r.err.code & ")")
          return outcomeOf(store, runId, rsFailed)
        log("task non-kritis " & task.id & " gagal (" & r.err.code & "); penutupan lanjut")

  snap = store.snapshot(runId)
  let summary = summaryOf(snap)
  if not canTransition(state, rsCompleted):
    raise newException(DayCloserError, "run tidak bisa diselesaikan dari state " & $state)
  store.sealRun(runId, now(), summary)
  outcomeOf(store, runId, rsCompleted, summary)

proc planRun*(registry: Registry; store: Store; runId: string; req: RunRequest): tuple[tasks, chunks: int] =
  ## Menyusun rencana dan menulis baris run dalam state `PLANNED`. Dipisah dari eksekusi supaya
  ## composition root bisa menulis audit `run.start` **setelah** baris run benar-benar ada.
  ## Rencana chunk dihitung sebelum baris ditulis: kegagalan plan tidak boleh meninggalkan run
  ## hantu.
  if req.levels == {}:
    raise newException(DayCloserError, "level penutupan kosong")
  let tasks = registry.resolve(req.levels)
  let ctx = TaskContext(runId: runId, scopeType: req.scopeType, scopeId: req.scopeId,
                        businessDate: req.businessDate, levels: req.levels, mode: req.mode,
                        chunkSize: req.config.chunkSize)
  var plan: seq[PlannedTask]
  for t in tasks:
    let chunks = planChunks(t, ctx, req.config.chunkSize)
    if chunks.isErr:
      raise newException(DayCloserError,
        "rencana chunk " & t.id & " gagal: " & chunks.error.code & " " & chunks.error.message)
    plan.add PlannedTask(taskId: t.id, kind: t.kind, critical: t.critical,
                         chunks: chunks.value())
  store.createRun(runId, req, plan)
  var totalChunks = 0
  for p in plan:
    totalChunks += p.chunks.len
  (tasks.len, totalChunks)

proc startRun*(registry: Registry; store: Store; runId: string; req: RunRequest;
               now: Now; sleepMs: Sleeper; log: Logger): RunOutcome =
  ## Rencanakan lalu langsung jalankan. `ctl` memakai `planRun` + `executeRun` terpisah agar
  ## audit `run.start` ditulis setelah baris run ada.
  let planned = planRun(registry, store, runId, req)
  log("run " & runId & " dibuat: " & $planned.tasks & " task, " & $planned.chunks &
      " chunk, level " & levelsCsv(req.levels))
  executeRun(registry, store, runId, now, sleepMs, log)

proc resumeRun*(registry: Registry; store: Store; runId: string;
                now: Now; sleepMs: Sleeper; log: Logger): RunOutcome =
  ## Melanjutkan run yang PAUSED/FAILED/BLOCKED atau yang prosesnya mati (state aktif tanpa
  ## pemegang lock). Pemanggil **wajib** memegang advisory lock run ini; kalau tidak, dua proses
  ## bisa menjalankan chunk yang sama.
  let snap = store.snapshot(runId)
  if not canResume(snap.state):
    raise newException(DayCloserError,
      "run " & runId & " sudah berakhir (" & $snap.state & "); tidak bisa dilanjutkan")
  discard validatedTasks(registry, snap)
  store.resetInFlight(runId)
  # Resume berarti "lanjutkan", jadi PAUSE yang tersimpan dibersihkan. CANCEL **tidak**:
  # membatalkan run yang sedang pause harus mungkin, dan satu-satunya jalur yang membacanya
  # adalah resume (tidak ada proses hidup yang sedang berjalan).
  if store.controlOf(runId) == rcPause:
    store.setControl(runId, rcNone)
  store.setRunState(runId, rsPrecheck, now(), "")
  log("run " & runId & " dilanjutkan dari " & $snap.state)
  executeRun(registry, store, runId, now, sleepMs, log)
