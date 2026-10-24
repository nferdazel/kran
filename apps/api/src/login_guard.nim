## Pembatas percobaan login (T-128).
##
## Kenapa ada: `POST /auth/login` menjalankan PBKDF2 600.000 iterasi **sambil memegang satu koneksi
## pool** (default 8). Tanpa pembatas, puluhan permintaan login palsu menghabiskan CPU dan pool
## sekaligus, dan lockout per akun tidak menolong karena penyerang menyebar ke banyak username.
##
## Dua lapis, keduanya diperiksa **sebelum** KDF:
##   1. semaphore konkurensi — jumlah login yang boleh berjalan bersamaan;
##   2. jendela per-IP — jumlah percobaan per menit.
##
## Angka di bawah adalah kapasitas proses (bukan kebijakan bisnis/regulasi): batas ini melindungi
## server, bukan mengatur produk. Bila kelak perlu dapat diubah tanpa deploy, pindahkan ke parameter
## `platform.security.*`; jangan menambah konstanta bisnis.
##
## Dua angka pertama dapat ditimpa lewat lingkungan (`KRAN_LOGIN_MAX_CONCURRENCY`,
## `KRAN_LOGIN_ATTEMPTS_PER_MINUTE`). Itu **kapasitas deployment**, bukan kebijakan: satu instance
## di belakang NAT kantor atau satu suite e2e yang login berulang kali dari 127.0.0.1 tidak boleh
## memaksa menurunkan mutu kode. Nilai yang tidak sah diabaikan (dipakai default), bukan membuat
## proses menolak start — pembatas yang salah baca tidak boleh mematikan layanan.

import std/[locks, os, strutils, times, tables]

const
  loginConcurrencyLimit* = 4   # nomagic:ok kapasitas KDF bersamaan per proses
  loginAttemptsPerMinute* = 10 # nomagic:ok batas percobaan login per IP per menit
  loginWindowSeconds* = 60.0

type
  LoginGuard* = ref object
    ## Dipakai satu proses. `nil` pada `AppContext` = pembatas tidak aktif (test/CLI).
    lock: Lock
    inflight: int
    windowStart: float64
    perIp: Table[string, int]
    concurrencyLimit: int
    attemptsPerMinute: int

proc positiveFromEnv(name: string, fallback: int): int =
  ## Nilai positif dari lingkungan; kosong/tidak sah/≤ 0 = default (fail-open ke nilai aman).
  let raw = getEnv(name).strip()
  if raw.len == 0:
    return fallback
  try:
    let value = parseInt(raw)
    if value > 0: value else: fallback
  except ValueError:
    fallback

proc newLoginGuard*(): LoginGuard =
  result = LoginGuard()
  initLock(result.lock)
  result.windowStart = epochTime()
  result.concurrencyLimit = positiveFromEnv("KRAN_LOGIN_MAX_CONCURRENCY", loginConcurrencyLimit)
  result.attemptsPerMinute = positiveFromEnv("KRAN_LOGIN_ATTEMPTS_PER_MINUTE",
    loginAttemptsPerMinute)

proc resetWindow(g: LoginGuard, now: float64) =
  if now - g.windowStart >= loginWindowSeconds:
    g.windowStart = now
    g.perIp.clear()

proc tryBegin*(g: LoginGuard, ip: string,
               now = epochTime()): tuple[allowed: bool, retryAfter: int] =
  ## Ambil satu slot login. `allowed = false` → pemanggil menjawab 429 dengan `Retry-After`.
  ## Slot yang berhasil **wajib** dilepas dengan `finish` (gunakan `defer`).
  if g.isNil:
    return (true, 0)
  withLock g.lock:
    g.resetWindow(now)
    if g.inflight >= g.concurrencyLimit:
      return (false, 1)
    let used = g.perIp.getOrDefault(ip, 0)
    if used >= g.attemptsPerMinute:
      let remaining = int(loginWindowSeconds - (now - g.windowStart))
      return (false, max(1, remaining))
    g.perIp[ip] = used + 1
    inc g.inflight
    result = (true, 0)

proc finish*(g: LoginGuard) =
  if g.isNil:
    return
  withLock g.lock:
    if g.inflight > 0:
      dec g.inflight
