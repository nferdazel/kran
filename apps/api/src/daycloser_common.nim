## Bagian yang dipakai bersama task day-close (`daycloser_gates`, `daycloser_ledger`, `ctl`).
##
## Isinya sengaja hanya hal yang **tidak** membawa aturan bisnis: batas tanggal pembacaan saldo
## kumulatif dan pembentuk konteks audit untuk perintah `ctl`. Menyalinnya ke tiap berkas task akan
## membuat tiga salinan yang menyimpang sendiri-sendiri.

import kernel/[auditcontext, clock, ids]

const
  earliestDate* = "0001-01-01"
    ## Batas bawah pembacaan saldo kumulatif: task saldo membandingkan angka **sampai** tanggal
    ## buku, jadi rentang dimulai sebelum jurnal pertama yang mungkin ada.

proc ctlAuditContext*(clock: Clock; reason: string): AuditContext =
  ## `ctl` tidak punya sesi: pelakunya dicatat lewat `device`, bukan user id palsu.
  newAuditContext(Id(""), device = "kran-api ctl", reason = reason, startedAt = clock.now())
