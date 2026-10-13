## scaffold — pembuat kerangka modul baru (spec §5.5, §27.B).
##
##   scaffold [--root <dir>] [--dry-run] <nama-modul>
##
## Keluar: 0 sukses, 1 nama tidak sah / modul sudah ada, 2 kesalahan pemakaian.

import std/os
import lib

proc usage() =
  stderr.writeLine("pemakaian: scaffold [--root <dir>] [--dry-run] <nama-modul>")

var root = getCurrentDir()
var dryRun = false
var name = ""

let args = commandLineParams()
var i = 0
while i < args.len:
  case args[i]
  of "--root":
    inc i
    if i >= args.len:
      usage()
      quit(2)
    root = absolutePath(args[i])
  of "--dry-run":
    dryRun = true
  of "--help", "-h":
    usage()
    quit(0)
  else:
    if name.len > 0:
      stderr.writeLine("argumen tidak dikenal: " & args[i])
      usage()
      quit(2)
    name = args[i]
  inc i

if name.len == 0:
  usage()
  quit(2)
if not dirExists(root):
  stderr.writeLine("akar tidak ditemukan: " & root)
  quit(2)

try:
  let written = writeModule(root, name, dryRun)
  let verb = if dryRun: "akan ditulis" else: "ditulis"
  echo "scaffold: modul `" & name & "` — " & $written.len & " berkas " & verb
  for p in written:
    echo "  " & p
  if not dryRun:
    echo "berikutnya: isi domain/core.nim + application/use_case.nim + MODULE.md, lalu"
    echo "verifikasi: ./task check && ./task test t" & sanitizedModuleName(name)
  quit(0)
except ScaffoldError as e:
  stderr.writeLine("scaffold: " & e.msg)
  quit(1)
