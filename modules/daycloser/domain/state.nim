## State machine & parsing (spec §11.3) — murni, tanpa I/O.
##
## Transisi ditegakkan di sini, bukan hanya oleh CHECK constraint: DB menjaga **domain nilai**,
## orkestrator menjaga **urutan**. Memisahkan keduanya membuat bug urutan terlihat di unit test,
## bukan setelah baris DB ditulis.

import std/strutils

import ./types

proc parseRunState*(s: string): RunState =
  for st in RunState:
    if $st == s.strip:
      return st
  raise newException(DayCloserError, "state run tidak dikenal: " & s)

proc parseTaskState*(s: string): TaskState =
  for st in TaskState:
    if $st == s.strip:
      return st
  raise newException(DayCloserError, "state task tidak dikenal: " & s)

proc parseChunkState*(s: string): ChunkState =
  for st in ChunkState:
    if $st == s.strip:
      return st
  raise newException(DayCloserError, "state chunk tidak dikenal: " & s)

proc parseRunControl*(s: string): RunControl =
  for c in RunControl:
    if $c == s.strip:
      return c
  raise newException(DayCloserError, "kontrol run tidak dikenal: " & s)

proc parseRunMode*(s: string): RunMode =
  for m in RunMode:
    if $m == s.strip:
      return m
  raise newException(DayCloserError, "mode run tidak dikenal: " & s)

proc parseTaskKind*(s: string): TaskKind =
  for k in TaskKind:
    if $k == s.strip:
      return k
  raise newException(DayCloserError, "jenis task tidak dikenal: " & s)

proc parseIdempotencyMode*(s: string): IdempotencyMode =
  for m in IdempotencyMode:
    if $m == s.strip:
      return m
  raise newException(DayCloserError, "mode idempotensi tidak dikenal: " & s)

proc parsePartitionStrategy*(s: string): PartitionStrategy =
  for p in PartitionStrategy:
    if $p == s.strip:
      return p
  raise newException(DayCloserError, "strategi partisi tidak dikenal: " & s)

proc parseTxnPolicy*(s: string): TxnPolicyDuringClose =
  for p in TxnPolicyDuringClose:
    if $p == s.strip:
      return p
  raise newException(DayCloserError, "kebijakan transaksi saat closing tidak dikenal: " & s)

proc canResume*(s: RunState): bool =
  ## Resume adalah **gerbang operator**, bukan transisi otomatis: ia boleh masuk kembali dari
  ## state mana pun yang belum selesai. `canTransition` tetap ketat untuk transisi normal
  ## (RUNNING → PRECHECK tidak sah sebagai langkah biasa), sehingga resume harus memakai
  ## pemeriksaan ini secara eksplisit — bukan menumpang aturan yang lebih longgar.
  s in {rsPlanned, rsPrecheck, rsRunning, rsPostcheck, rsPaused, rsFailed, rsBlocked}

proc canTransition*(current, next: RunState): bool =
  ## Satu jalur maju + pause/cancel di batas fase. Terminal tidak bisa dibuka kembali.
  case current
  of rsPlanned: next in {rsPrecheck, rsCanceled}
  of rsPrecheck: next in {rsRunning, rsBlocked, rsFailed, rsPaused, rsCanceled}
  of rsRunning: next in {rsPostcheck, rsFailed, rsPaused, rsCanceled}
  of rsPostcheck: next in {rsCompleted, rsBlocked, rsFailed, rsPaused, rsCanceled}
  # Resume selalu masuk kembali lewat PRECHECK; fase yang sudah selesai dilewati berdasarkan
  # state task, sehingga orkestrator tidak perlu mengingat "paused di fase mana".
  of rsPaused: next in {rsPrecheck, rsCanceled}
  # FAILED/BLOCKED bukan jalan buntu: operator memperbaiki sebabnya lalu `daycloser-resume`.
  # COMPLETED & CANCELED tetap terminal.
  of rsFailed: next in {rsPrecheck, rsCanceled}
  of rsBlocked: next in {rsPrecheck, rsCanceled}
  of rsCompleted, rsCanceled: false

proc canTransition*(current, next: TaskState): bool =
  case current
  of tsPending: next in {tsReady, tsCanceled}
  of tsReady: next in {tsRunning, tsCanceled}
  of tsRunning: next in {tsSucceeded, tsFailed, tsSkipped, tsPending}
  of tsFailed: next in {tsReady, tsCanceled}
  of tsSucceeded, tsSkipped, tsCanceled: false

proc canTransition*(current, next: ChunkState): bool =
  case current
  of csPending: next == csRunning
  of csRunning: next in {csSucceeded, csFailed, csPending}
  of csSucceeded: false
  of csFailed: next == csRunning
