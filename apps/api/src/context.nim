## Konteks aplikasi (spec §12.5): nilai yang dipegang handler, bukan nilai bisnis.
##
## Dipisah dari `health.nim` supaya modul fitur (mis. `events.nim`) bisa mendefinisikan tipe
## layanannya tanpa impor melingkar: `context` → fitur, sedangkan `health`/`routes` → `context`.
##
## `health.nim` me-*re-export* modul ini, jadi pemanggil lama (`main.nim`, test) tetap melihat
## `AppContext`/`ReadinessCheck` dari `health` seperti sebelumnya.

import ./events

type
  CheckStatus* = enum
    csOk = "ok"
    csFailed = "failed"

  ReadinessCheck* = object
    name*: string
    status*: CheckStatus
    detail*: string

  ReadinessProbe* = proc(): seq[ReadinessCheck] {.gcsafe.}

  AppContext* = object
    version*: string
    role*: string
    startedAt*: float ## epoch seconds; dari `epochTime()` saat proses start
    readiness*: ReadinessProbe
    ## `nil` = realtime tidak dikonfigurasi (mis. `CBS_DATABASE_URL` kosong). Rutenya membalas
    ## problem `NOT_IMPLEMENTED` alih-alih memaksa proses mati.
    events*: EventService
