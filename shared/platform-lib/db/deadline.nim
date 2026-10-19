## Batas waktu blok kerja DB (T-065).
##
## Kenapa perlu: `connect_timeout` hanya membatasi **pembukaan** koneksi, dan keepalive TCP hanya
## memutus koneksi bila peer TCP berhenti menjawab probe. Bila ada perantara yang tetap meng-ACK
## (tunnel SSH hidup tetapi jalur remote mati), kueri pada koneksi yang sudah hidup menggantung
## **tanpa batas** — `statement_timeout` juga tidak menolong karena kueri tidak pernah sampai ke
## server. Terbukti > 30 s pada perantara TCP yang membeku (`docs/tasks/T-065.md`).
##
## Cara kerja: satu thread pemantau per proses. Pemanggil mendaftarkan `(fd, batas waktu)`; saat
## batas lewat, pemantau memanggil `shutdown(fd, SHUT_RDWR)` sehingga I/O libpq yang sedang menunggu
## gagal seketika. Pemanggil **wajib membuang** koneksi yang kena batas: status protokolnya tidak
## bisa dipercaya lagi (`pool.nim` melakukan ini).
##
## Batas ini per **blok kerja** (satu `withConn`/`withTx`), bukan per kueri individual: satu blok
## bisa berisi beberapa kueri dan semuanya berbagi anggaran waktu yang sama. Bila anggaran habis
## tepat setelah blok **selesai** (kueri terakhir sukses), pemanggil tetap menerima hasilnya —
## koneksinya saja yang dibuang (`pool.nim`).
##
## Batas memakai jam monotonik (`getMonoTime`), bukan jam dinding: lompatan NTP tidak boleh memutus
## blok yang sedang berjalan.
##
## Degradasi yang disengaja: bila tabel slot penuh atau thread pemantau gagal dibuat, `armDeadline`
## mengembalikan token 0 (= tanpa batas). Memantau adalah lapisan tambahan; kegagalannya tidak boleh
## membuat kueri yang sehat gagal. Jumlah slot jauh di atas ukuran pool yang wajar.

import std/[locks, monotimes, os, posix]

const
  maxGuards* = 256 ## cukup untuk semua pool aplikasi; pemakaian di luar ini = tanpa batas
  watchdogTickMs = 50

type
  DeadlineGuard* = object
    ## Token pendaftaran; `token == 0` berarti tidak ada batas (fd tidak valid / batas <= 0).
    token*: uint64

  WatchdogArg = object

  Slot = object
    used: bool
    token: uint64
    fd: SocketHandle
    atMs: float64
    fired: bool

var
  guardLock: Lock
  slots: array[maxGuards, Slot]
  nextToken: uint64
  watchdogStarted = false
  watchdogThread: Thread[WatchdogArg]

initLock(guardLock)

proc monoMs(): float64 =
  ## Jam monotonik dalam milidetik (tahan lompatan jam dinding).
  float(getMonoTime().ticks) / 1_000_000.0

proc watchdogMain(_: WatchdogArg) {.thread.} =
  while true:
    sleep(watchdogTickMs)
    let now = monoMs()
    withLock guardLock:
      for i in 0 ..< maxGuards:
        if slots[i].used and not slots[i].fired and now >= slots[i].atMs:
          slots[i].fired = true
          # `shutdown` tidak memblokir, dan harus di dalam lock: bila dilepas lebih dulu, pemilik
          # bisa `disarm` + `pqfinish` dan fd itu dipakai ulang koneksi lain — kita lalu memutus
          # koneksi yang tidak bersalah.
          discard shutdown(slots[i].fd, SHUT_RDWR)

proc armDeadline*(fd: int32, timeoutMs: int): DeadlineGuard =
  ## Daftarkan `fd` dengan batas `timeoutMs`. `fd < 0` atau `timeoutMs <= 0` = tanpa batas.
  ## Bila tabel penuh, juga tanpa batas (lebih baik daripada crash; jumlahnya jauh di atas
  ## `poolSize` yang wajar).
  result.token = 0
  if fd < 0 or timeoutMs <= 0:
    return
  withLock guardLock:
    if not watchdogStarted:
      # Di dalam lock supaya dua thread tidak membuat dua pemantau. Penanda baru diset setelah
      # thread benar-benar ada; kalau gagal, panggilan berikutnya mencoba lagi.
      try:
        createThread(watchdogThread, watchdogMain, WatchdogArg())
        watchdogStarted = true
      except CatchableError:
        discard
    for i in 0 ..< maxGuards:
      if not slots[i].used:
        inc nextToken
        slots[i] = Slot(used: true, token: nextToken, fd: SocketHandle(fd),
                        atMs: monoMs() + float(timeoutMs))
        result.token = nextToken
        break

proc disarmDeadline*(g: DeadlineGuard): bool =
  ## Lepas pendaftaran. `true` bila batas sudah terlanjur lewat — artinya socket sudah
  ## di-`shutdown` dan koneksinya harus dibuang.
  if g.token == 0:
    return false
  withLock guardLock:
    for i in 0 ..< maxGuards:
      if slots[i].used and slots[i].token == g.token:
        result = slots[i].fired
        slots[i].used = false
        return
  false
