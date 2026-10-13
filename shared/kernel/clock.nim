## `Clock` — sumber waktu yang di-inject (spec §5.1: domain tanpa I/O, waktu & ID di-inject).
##
## Selalu UTC. `FakeClock` untuk test/ day-close simulation (spec §20 "Time-travel").
##
## Catatan: `Clock.businessDate(scope)` (kalender & hari libur dari parameter) **bukan** di sini
## — itu milik `platform/calendar` (T-007). Kernel hanya tahu waktu UTC.

import std/times

type
  ## Abstraksi jam. `now()` selalu mengembalikan `DateTime` UTC.
  Clock* = ref object of RootObj
  ## Jam sistem nyata.
  SystemClock* = ref object of Clock
  ## Jam palsu yang bisa di-set/di-advance (test, simulasi day-close).
  FakeClock* = ref object of Clock
    current*: DateTime

proc utcNow*(): DateTime =
  ## Waktu UTC sekarang dari fungsi, tanpa `Clock` (dipakai bootstrap).
  now().utc

method now*(c: Clock): DateTime {.base.} =
  ## Base: jatuh ke waktu UTC sistem.
  utcNow()

method now*(c: SystemClock): DateTime =
  ## Waktu UTC sistem.
  utcNow()

method now*(c: FakeClock): DateTime =
  ## Waktu palsu yang di-set.
  c.current

proc systemClock*(): SystemClock =
  ## Buat jam sistem.
  SystemClock()

proc fakeClock*(start: DateTime): FakeClock =
  ## Buat jam palsu mulai dari `start` (idealnya UTC).
  FakeClock(current: start)

proc setNow*(c: FakeClock, dt: DateTime) =
  ## Set waktu palsu.
  c.current = dt

proc advance*(c: FakeClock, seconds: int64) =
  ## Majukan waktu palsu `seconds` detik.
  c.current = c.current + initDuration(seconds = seconds)
