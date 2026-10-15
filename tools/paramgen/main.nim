## paramgen — generate konstanta parameter, katalog TS, dan seed SQL (spec §10.3).
##
##   paramgen --root <dir> [--gen | --check]
##
## `--check` (dipakai `./task check`) tidak menulis apa pun dan keluar 1 bila artefak di disk
## berbeda dari hasil generate. `--gen` menulis ulang artefak.

import std/[os, strutils]
import lib

var root = getCurrentDir()
var doCheck = false
var doGen = false

let args = commandLineParams()
var i = 0
while i < args.len:
  case args[i]
  of "--root":
    inc i
    if i >= args.len:
      stderr.writeLine("--root butuh nilai")
      quit(2)
    root = absolutePath(args[i])
  of "--check": doCheck = true
  of "--gen": doGen = true
  of "--help", "-h":
    echo "pemakaian: paramgen --root <dir> [--gen|--check]"
    quit(0)
  else:
    stderr.writeLine("argumen tidak dikenal: " & args[i])
    quit(2)
  inc i

if not dirExists(root):
  stderr.writeLine("akar tidak ditemukan: " & root)
  quit(2)
if not doCheck and not doGen:
  doGen = true

try:
  let belumDisepakati = undefinedApprovalSemantics(loadAllDefs(root))
  if belumDisepakati.len > 0:
    stderr.writeLine("paramgen: `requires_approval: false` belum punya arti yang disepakati " &
      "(docs/OPEN_ITEMS.md O-039; dijalankan bersama T-016): " & belumDisepakati.join(", "))
    quit(2)

  let seeds = moduleSeedPaths(root)
  if doCheck:
    var note = ""
    if runCheck(root, note):
      echo "paramgen: sinkron (" & $seeds.len & " berkas seeds/params.yaml)"
      quit(0)
    stderr.writeLine("paramgen: KODE != DEFINISI")
    stderr.writeLine(note)
    stderr.writeLine("jalankan: ./task paramgen-gen")
    quit(1)
  let written = runGen(root)
  echo "paramgen: " & $written.len & " artefak diperbarui"
  for o in written:
    echo "  " & o.path
  quit(0)
except ParamgenError as e:
  stderr.writeLine("paramgen: definisi tidak valid: " & e.msg)
  quit(2)
