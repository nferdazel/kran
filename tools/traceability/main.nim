## traceability — gate requirement regulasi ↔ kontrol ↔ test (spec §4.4, O-027).
##
##   traceability <root> [register.yaml]
##
## Keluar 1 bila ada requirement `active` tanpa kontrol/test, atau rujukan yang tidak ada.

import std/[os, sequtils]
import lib

let args = commandLineParams()
if args.len < 1:
  stderr.writeLine("pemakaian: traceability <root> [register.yaml]")
  quit(2)

let root = absolutePath(args[0])
if not dirExists(root):
  stderr.writeLine("akar tidak ditemukan: " & root)
  quit(2)

let registerPath =
  if args.len >= 2: absolutePath(args[1])
  else: root / "docs" / "compliance" / "register.yaml"

var register: Register
try:
  register = loadRegister(registerPath)
except CatchableError as e:
  stderr.writeLine("traceability: " & e.msg)
  quit(2)

var problems = register.problems
try:
  problems.add validate(root, register)
except CatchableError as e:
  stderr.writeLine("traceability: gagal membaca seeds/params.yaml: " & e.msg)
  quit(2)

let active = register.requirements.filterIt(it.status == "active").len
let deferred = register.requirements.len - active

if problems.len == 0:
  echo "traceability: " & $active & " requirement aktif punya kontrol + test, " & $deferred &
    " deferred"
  quit(0)

echo "traceability: " & $problems.len & " temuan"
for p in problems:
  echo "  " & p.requirement & ": " & p.message
quit(1)
