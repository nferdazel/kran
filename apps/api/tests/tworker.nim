## Test unit konsumen posting (tanpa database): worker berhenti dengan tenang.
##
## Yang dibuktikan di sini hanya dua hal: flag permintaan berhenti benar-benar terbaca, dan tidur
## poll dipotong saat flag itu menyala (tanpa pemotongan, worker baru sadar setelah poll penuh —
## parameter `ledger.posting.poll_interval_ms` bisa beberapa detik). SIGTERM sungguhan ke container
## pid 1 diverifikasi di host, bukan oleh test ini.

import std/[times, unittest]

import ../src/posting

suite "posting: berhenti dengan tenang":
  test "tidur poll dipotong saat permintaan berhenti masuk":
    check not workerStopRequested()
    requestWorkerStop()
    check workerStopRequested()
    # 10 detik dipilih supaya test ini merah (bukan sekadar lambat) bila pengecekan stop dicabut:
    # tanpa pemotongan, elapsed ikut menjadi ~10 detik.
    let started = epochTime()
    sleepInterruptible(10_000)
    check (epochTime() - started) < 1.0
