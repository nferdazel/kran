## lint-nomagic — deteksi magic number bisnis di domain/application (spec §10.4).
##
##   lint-nomagic <root>
##
## Keluar 1 bila ada temuan. Aturan & escape hatch: lihat `lib.nim`.

import std/os
import lib

let args = commandLineParams()
if args.len < 1:
  stderr.writeLine("pemakaian: lint-nomagic <root>")
  quit(2)

let root = absolutePath(args[0])
if not dirExists(root):
  stderr.writeLine("akar tidak ditemukan: " & root)
  quit(2)

let violations = scanRoot(root)
if violations.len == 0:
  echo "lint-nomagic: tidak ada magic number bisnis di domain/application"
  quit(0)

echo "lint-nomagic: " & $violations.len & " temuan"
for v in violations:
  echo "  " & formatViolation(v)
quit(1)
