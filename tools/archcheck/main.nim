## archcheck — penegak batas arsitektur (spec §5.1, §6.3).
##
##   archcheck <root>                     periksa terhadap baseline
##   archcheck <root> --update-baseline    tulis ulang baseline (hanya untuk tangkapan awal)
##
## Keluar 1 bila ada pelanggaran baru atau baseline basi. Aturan & escape hatch: lihat `lib.nim`.

import std/os
import lib

var root = ""
var updateBaseline = false
for arg in commandLineParams():
  if arg == "--update-baseline":
    updateBaseline = true
  elif root.len == 0:
    root = arg
  else:
    stderr.writeLine("argumen tidak dikenal: " & arg)
    quit(2)

if root.len == 0:
  stderr.writeLine("pemakaian: archcheck <root> [--update-baseline]")
  quit(2)

root = absolutePath(root)
if not dirExists(root):
  stderr.writeLine("akar tidak ditemukan: " & root)
  quit(2)

let baselinePath = root / "tools" / "archcheck" / "baseline.txt"
let violations = scanRoot(root)

if updateBaseline:
  writeFile(baselinePath, renderBaseline(violations))
  echo "archcheck: baseline ditulis, " & $violations.len &
    " pelanggaran tercatat -> " & baselinePath
  quit(0)

var entries: seq[string]
if fileExists(baselinePath):
  entries = parseBaseline(readFile(baselinePath))

let diff = compareBaseline(violations, entries)
if diff.newViolations.len == 0 and diff.staleEntries.len == 0:
  echo "archcheck: tidak ada pelanggaran baru (baseline " & $entries.len & " entri)"
  quit(0)

if diff.newViolations.len > 0:
  echo "archcheck: " & $diff.newViolations.len & " pelanggaran baru (tidak ada di baseline)"
  for v in diff.newViolations:
    echo "  " & formatViolation(v)

if diff.staleEntries.len > 0:
  echo "archcheck: baseline stale, shrink it (" & $diff.staleEntries.len &
    " entri tidak lagi terjadi)"
  for e in diff.staleEntries:
    echo "  " & e

quit(1)
