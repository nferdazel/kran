import std/unittest
import std/strutils

import ../lib

const
  domLending = "modules/lending/domain/interest.nim"
  appLending = "modules/lending/application/accrue.nim"
  infraLending = "modules/lending/infrastructure/pg_repo.nim"
  apiLending = "modules/lending/api.nim"
  kernelClock = "shared/kernel/clock.nim"

suite "archcheck: aturan A (domain murni)":
  test "domain import lapisan sendiri = pelanggaran":
    let v = scanSource(domLending, "import application/accrue\n")
    check v.len == 1
    check v[0].rule == "A"
    check v[0].line == 1

  test "domain import infrastructure/interface (relatif) = pelanggaran":
    check scanSource(domLending, "import ../infrastructure/pg_repo\n").len == 1
    check scanSource(domLending, "from ../interface/http import handler\n").len == 1

  test "domain import driver DB / async busuk = pelanggaran":
    for bad in ["db_connector", "db_connector/postgres", "std/asyncdispatch",
                "std/net", "std/httpclient", "std/osproc", "std/os"]:
      check scanSource(domLending, "import " & bad & "\n").len == 1

  test "domain import stdlib murni & kernel = bersih":
    check scanSource(domLending, "import std/[strutils, math, times]\n").len == 0
    check scanSource(domLending, "import kernel\n").len == 0
    check scanSource(domLending, "import kernel/money\n").len == 0
    check scanSource(domLending, "import ./errors\n").len == 0

  test "domain import internal modul lain = pelanggaran aturan C":
    let v = scanSource(domLending, "import deposit/domain/account\n")
    check v.len == 1
    check v[0].rule == "C"
    check scanSource(domLending, "import deposit/api\n").len == 0
    check scanSource(domLending, "import lending/domain/other\n").len == 0

suite "archcheck: aturan B (application tidak menyentuh infra)":
  test "infrastructure/interface/driver = pelanggaran":
    check scanSource(appLending, "import infrastructure/pg_repo\n")[0].rule == "B"
    check scanSource(appLending, "import interface/http\n").len == 1
    check scanSource(appLending, "import db_connector/postgres\n").len == 1
    check scanSource(appLending, "import std/httpclient\n").len == 1

  test "domain sendiri & port sendiri = bersih":
    check scanSource(appLending, "import ../domain/interest\n").len == 0
    check scanSource(appLending, "import std/asyncdispatch\n").len == 0
    check scanSource(appLending, "import kernel\n").len == 0

suite "archcheck: aturan C (batas antar-modul)":
  test "infrastructure/interface/api modul lain juga tunduk aturan C":
    check scanSource(infraLending, "import deposit/infrastructure/pg\n")[0].rule == "C"
    check scanSource(apiLending, "import deposit/domain/account\n")[0].rule == "C"
    check scanSource(apiLending, "import deposit/api\n").len == 0

suite "archcheck: aturan D (kernel murni)":
  test "kernel tidak boleh menyentuh modul/DB":
    check scanSource(kernelClock, "import modules/lending/domain/x\n")[0].rule == "D"
    check scanSource(kernelClock, "import lending/domain/x\n")[0].rule == "D"
    check scanSource(kernelClock, "import db_connector\n")[0].rule == "D"

  test "kernel boleh stdlib & sesama kernel":
    check scanSource(kernelClock, "import std/times\n").len == 0
    check scanSource(kernelClock, "import ./result\n").len == 0
    check scanSource(kernelClock, "import kernel/ids\n").len == 0

suite "archcheck: escape hatch & klasifikasi":
  test "`archcheck:ok` dengan alasan melewati pelanggaran":
    check scanSource(domLending,
      "import db_connector # archcheck:ok spike migrasi, dihapus T-999\n").len == 0

  test "`archcheck:ok` tanpa alasan justru dilaporkan":
    let v = scanSource(domLending, "import db_connector # archcheck:ok\n")
    check v.len == 1
    check v[0].rule == "E"

  test "berkas di luar struktur / tests / generated dilewati":
    check scanSource("README.md", "import db_connector\n").len == 0
    check scanSource("modules/lending/tests/tx.nim", "import infrastructure/x\n").len == 0
    check scanSource("shared/kernel/generated/paramkeys.nim", "import db_connector\n").len == 0
    check scanSource("tools/paramgen/main.nim", "import infrastructure/x\n").len == 0
    check scanSource("apps/api/src/main.nim", "import db_connector\n").len == 0

  test "multi-import satu baris diperiksa semua":
    let v = scanSource(domLending, "import std/strutils, db_connector\n")
    check v.len == 1
    check v[0].message.contains("db_connector")

  test "komentar di belakang import tidak mengaburkan pemeriksaan":
    check scanSource(domLending, "import db_connector # sementara\n")[0].rule == "A"
    check scanSource(domLending, "# import db_connector\n").len == 0

  test "expandBracketForm":
    check expandBracketForm("std/[a, b]") == @["std/a", "std/b"]
    check expandBracketForm("std/strutils") == @["std/strutils"]

  test "paket pihak ketiga bukan pelanggaran batas modul":
    check scanSource(infraLending, "import db_connector/db_postgres\n").len == 0
    check scanSource(infraLending, "import db_connector/postgres\n").len == 0
    check scanSource(infraLending, "import yaml\n").len == 0
    check scanSource(infraLending, "import std/json, db_connector/db_postgres\n").len == 0
    # ...tetapi internal modul bisnis tetap pelanggaran
    let v = scanSource(infraLending, "import deposit/infrastructure/pg_repo\n")
    check v.len == 1
    check v[0].rule == "C"

  test "import berkutip (nama dir bertanda hubung) tidak salah dianggap modul bisnis":
    let rel = "modules/lending/infrastructure/pg_repo.nim"
    check scanSource(rel, "import \"platform-lib/db/pool\"\n").len == 0
    check scanSource(rel, "import \"platform-lib/log\"\n").len == 0
    check scanSource(domLending, "import \"platform-lib/db/pool\"\n").len == 1
    check unquote("\"platform-lib/db/pool\"") == "platform-lib/db/pool"
    check unquote("platform-lib/db/pool") == "platform-lib/db/pool"
