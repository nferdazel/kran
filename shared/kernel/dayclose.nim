## Level penutupan (spec §11.2) — kosakata bersama kalender & `daycloser`.
##
## Nilai level **bukan** nilai bisnis: ia nama tahap orkestrasi. Yang menentukan *kapan* sebuah
## level dijalankan adalah kalender (`platform.domain.calendar`, dari parameter + tabel hari
## libur), bukan daftar ini. Ditempatkan di kernel supaya `platform` (penentu level) dan
## `daycloser` (pelaksana) memakai satu tipe tanpa saling menembus internal modul.

import std/strutils

type
  CloseLevel* = enum
    ## `EOW` opsional di spec; belum ada parameter hari penutupan mingguan, jadi kalender
    ## belum pernah menghasilkannya. Tipe tetap memuatnya agar registry task bisa menyatakan
    ## ketergantungan mingguan tanpa perubahan tipe saat parameternya lahir.
    clEOD = "EOD"
    clEOW = "EOW"
    clEOM = "EOM"
    clEOQ = "EOQ"
    clEOY = "EOY"

proc parseCloseLevel*(s: string): CloseLevel =
  ## Raise `ValueError` untuk nilai tak dikenal — satu-satunya sumber daftar level yang sah.
  let t = s.strip
  for lvl in CloseLevel:
    if $lvl == t:
      return lvl
  raise newException(ValueError, "close level tidak dikenal: " & s)

proc levelsCsv*(levels: set[CloseLevel]): string =
  ## Urutan tetap (EOD, EOW, EOM, EOQ, EOY) supaya deterministik di DB, log, dan test.
  var parts: seq[string]
  for lvl in CloseLevel:
    if lvl in levels:
      parts.add $lvl
  parts.join(",")

proc parseLevelsCsv*(s: string): set[CloseLevel] =
  ## Kebalikan `levelsCsv`. String kosong = himpunan kosong. Duplikat tidak berpengaruh.
  for part in s.split(','):
    let t = part.strip
    if t.len > 0:
      result.incl parseCloseLevel(t)
