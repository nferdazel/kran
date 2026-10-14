## CLI `tools/i18ncheck` — dipanggil `./task i18n` (spec §16.3).
##
##   i18ncheck <root-repo> [--json]
##
## Exit 0 = katalog lengkap; exit 1 = ada temuan (cetak daftarnya ke stderr).

import std/os

import ./lib

proc usage() =
  stderr.writeLine "pemakaian: i18ncheck <root-repo> [--json]"
  quit(2)

let args = commandLineParams()
if args.len == 0:
  usage()

var root = args[0]
if not dirExists(root):
  stderr.writeLine "root repo tidak ada: " & root
  quit(2)
root = absolutePath(root)

let report = checkCatalogs(root)
if "--json" in args:
  stdout.writeLine $report
else:
  stdout.write renderReport(report)

if report.problems.len > 0:
  quit(1)
