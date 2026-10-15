## Keadaan berhenti (drain) proses API — T-032/O-047.
##
## Modul kecil sendiri supaya `main` (penunggu sinyal), `server` (pembungkus handler), dan `health`
## (readiness) bisa memakainya tanpa ketergantungan melingkar. Isinya sengaja hanya dua nilai atomik:
## tidak ada I/O, tidak ada DB, tidak ada Mummy — aman disentuh dari thread mana pun.

import std/atomics

var inFlight: Atomic[int]
var draining: Atomic[bool]

proc beginRequest*() =
  ## Dipanggil di awal setiap permintaan HTTP yang masuk ke router.
  discard inFlight.fetchAdd(1)

proc endRequest*() =
  ## Dipanggil di akhir permintaan (termasuk saat handler melempar), supaya hitungan tidak bocor.
  discard inFlight.fetchSub(1)

proc inFlightCount*(): int =
  ## Jumlah permintaan yang sedang berjalan di proses ini.
  inFlight.load()

proc startDraining*() =
  ## Dipanggil sekali saat SIGINT/SIGTERM diterima.
  draining.store(true)

proc isDraining*(): bool =
  ## True sejak proses mulai berhenti. Dipakai readiness: penyeimbang beban harus berhenti mengirim
  ## permintaan baru selagi yang sedang berjalan diselesaikan.
  draining.load()
