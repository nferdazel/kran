## Clock — waktu di-inject supaya domain deterministik & bisa di-time-travel (spec §5.1, §20).
##
## `Clock.businessDate(scope)` **tidak** ada di sini: business date adalah state ber-DB
## (spec §9.3), jadi milik `platform/calendar` (T-007). Kernel hanya menyediakan waktu teknis
## (UTC) dan versi palsunya untuk test/simulasi day-close.

import std/times

type
  Clock* = ref object of RootObj
  SystemClock* = ref object of Clock
  FakeClock* = ref object of Clock
    current*: DateTime

proc utcNow*(): DateTime {.inline.} =
  ## Waktu sistem dalam UTC (spec §16.2: disimpan UTC, tampilan zona per cabang).
  times.now().utc

method now*(c: Clock): DateTime {.base.} =
  utcNow()

method now*(c: SystemClock): DateTime =
  utcNow()

method now*(c: FakeClock): DateTime =
  c.current

proc systemClock*(): SystemClock =
  SystemClock()

proc fakeClock*(start: DateTime): FakeClock =
  ## Jam palsu selalu UTC; simulasi day-close memakai ini (spec §11.7, §20).
  FakeClock(current: start.utc)

proc setNow*(c: FakeClock, dt: DateTime) =
  c.current = dt.utc

proc advance*(c: FakeClock, seconds: int64) =
  c.current = c.current + initDuration(seconds = int(seconds))
