## archcheck — penegak batas arsitektur (spec §5.1, §6.3).
##
##   archcheck <root>
##
## Keluar 1 bila ada pelanggaran. Aturan & escape hatch: lihat `lib.nim`.

import std/os
import lib

let args = commandLineParams()
if args.len < 1:
  stderr.writeLine("pemakaian: archcheck <root>")
  quit(2)

let root = absolutePath(args[0])
if not dirExists(root):
  stderr.writeLine("akar tidak ditemukan: " & root)
  quit(2)

let violations = scanRoot(root)
if violations.len == 0:
  echo "archcheck: tidak ada pelanggaran batas arsitektur"
  quit(0)

echo "archcheck: " & $violations.len & " pelanggaran"
for v in violations:
  echo "  " & formatViolation(v)
quit(1)
