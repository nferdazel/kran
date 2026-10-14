## Konteks aplikasi (spec §12.5): nilai yang dipegang handler, bukan nilai bisnis.
##
## Dipisah dari `health.nim` supaya modul fitur (mis. `events.nim`) bisa mendefinisikan tipe
## layanannya tanpa impor melingkar: `context` → fitur, sedangkan `health`/`routes` → `context`.
##
## `health.nim` me-*re-export* modul ini, jadi pemanggil lama (`main.nim`, test) tetap melihat
## `AppContext`/`ReadinessCheck` dari `health` seperti sebelumnya.

import std/times

import "platform-lib/db/pool"

import kernel/clock

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
    ## `nil` = tidak ada basis data: rute yang membutuhkannya membalas 501. Poolnya sama dengan
    ## yang dipakai `events` (satu pool per proses, minus satu koneksi pendengar milik pump).
    pool*: DbPool
    ## Sumber waktu untuk sesi/audit. Dari luar (inject) supaya test bisa memakai `FakeClock`.
    clock*: Clock

proc businessDateIso*(clock: Clock): string =
  ## Tanggal "hari ini" versi UTC yang dipakai untuk membaca parameter efektif-dated.
  ## Fase 0 belum punya kalender institusi berisi baris (tabel `business_date` kosong), jadi
  ## `auth_service.businessDateFor` pun jatuh ke tanggal UTC yang sama — satu perilaku, bukan dua.
  let now = clock.now()
  format(now.utc, "yyyy-MM-dd")
