## Bentuk JSON tanggal buku institusi (kontrak `DayCloseBusinessDate`).
##
## Satu serializer untuk dua respons — `GET /api/v1/dayclose/status` dan `GET /api/v1/auth/session`
## (O-116). Bentuk tanggal buku tidak boleh berbeda tergantung rute yang membacanya; dua salinan
## berarti dua tempat yang bisa menyimpang saat kontrak berubah.

import std/json

import platform/domain/calendar
import platform/infrastructure/calendar_repo

proc businessDateJson*(row: BusinessDateRow): JsonNode =
  ## `frozenAt` = waktu state terakhir berubah. Tanggal `OPEN` belum beku, jadi `null`.
  let frozenAt = if row.state == bdsOpen: newJNull() else: %row.updatedAt
  %*{"date": row.currentDate, "state": $row.state, "frozenAt": frozenAt}
