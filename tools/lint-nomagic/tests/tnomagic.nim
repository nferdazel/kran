import std/unittest
import std/[strutils, sequtils]

import ../lib

const
  dom = "modules/lending/domain/collectibility.nim"
  app = "modules/lending/application/accrue.nim"
  handler = "apps/api/src/handlers_party.nim"

suite "lint-nomagic: cakupan pemindaian":
  test "modules/*/domain|application dan apps/api/src":
    check isScanned(dom)
    check isScanned(app)
    check not isScanned("modules/lending/infrastructure/pg.nim")
    check not isScanned("modules/lending/tests/tx.nim")
    check not isScanned("shared/kernel/money.nim")
    check not isScanned("shared/kernel/generated/paramkeys.nim")
    check not isScanned("tools/paramgen/main.nim")

  test "apps/api/src ikut dipindai, kecuali tests/ dan generated/":
    check isScanned("apps/api/src/main.nim")
    check isScanned("apps/api/src/handlers_party.nim")
    check isScanned("apps/api/src/daycloser/auto.nim")
    check not isScanned("apps/api/src/generated/paramkeys.nim")
    check not isScanned("apps/api/tests/itapi_lending.nim")
    check not isScanned("apps/web/src/main.ts")

  test "isHandlerPath hanya apps/api/src":
    check isHandlerPath("apps/api/src/handlers_party.nim")
    check not isHandlerPath("modules/lending/domain/collectibility.nim")
    check not isHandlerPath("apps/api/tests/itapi_lending.nim")

suite "lint-nomagic: angka":
  test "angka bisnis ditolak":
    check scanSource(dom, "let dpdKl = 91\n").len == 1
    check scanSource(dom, "let limit = 50000000\n").len == 1
    check scanSource(dom, "const graceDays = 7\n").len == 1
    check scanSource(dom, "let flag = -91\n").len == 1

  test "desimal selalu ditolak (pasti rate/fee/ambang)":
    check scanSource(dom, "let rate = 0.05\n").len == 1
    check scanSource(dom, "let rasio = 12.5\n").len == 1
    check scanSource(dom, "let u = 1.0\n")[0].message.contains("desimal")

  test "konstanta teknis lolos":
    for ok in ["let a = 0", "let b = 1", "let c = 2", "let d = 12", "let e = 24",
               "let f = 60", "let g = 100", "let h = 1000", "let i = 1024",
               "let j = 1_000"]:
      check scanSource(dom, ok & "\n").len == 0

  test "angka di dalam identifier/komentar tidak salah tertangkap":
    check scanSource(dom, "let t1234 = value\n").len == 0
    check scanSource(dom, "# 91\n").len == 0
    check scanSource(dom, "let x = 0 # 91\n").len == 0

  test "suffix tipe Nim tidak mengganggu":
    check scanSource(dom, "let x: int64 = 91'i64\n").len == 1
    check scanSource(dom, "let y = 12'u8\n").len == 0

suite "lint-nomagic: string":
  test "string bernilai bisnis ditolak":
    check scanSource(dom, "let s = \"Rp 1.000.000\"\n").len == 1
    check scanSource(dom, "let s = \"12.5%\"\n").len == 1
    check scanSource(dom, "let s = \"1000\"\n").len == 1

  test "string non-bisnis lolos":
    check scanSource(dom, "let s = \"lending.collectibility.dpd.kl\"\n").len == 0
    check scanSource(dom, "let s = \"DEP-1001\"\n").len == 0
    check scanSource(dom, "let s = \"error.money.invalid\"\n").len == 0
    check scanSource(dom, "let s = \"1\"\n").len == 0

suite "lint-nomagic: escape hatch":
  test "nomagic:ok dengan alasan melewati temuan":
    check scanSource(dom, "let dpd = 91 # nomagic:ok nilai dari test fixture\n").len == 0

  test "nomagic:ok tanpa alasan dilaporkan":
    let v = scanSource(dom, "let dpd = 91 # nomagic:ok\n")
    check v.len == 1
    check v[0].message.contains("tanpa alasan")

  test "escape hatch juga berlaku untuk string":
    check scanSource(dom, "let s = \"Rp 5\" # nomagic:ok pesan cetak\n").len == 0

suite "lint-nomagic: allowlist teknis handler (T-174)":
  test "kode status HTTP di apps/api/src lolos":
    for code in [200, 201, 204, 400, 401, 403, 404, 405, 409, 415, 426, 429, 500, 501, 503]:
      check scanSource(handler, "req.respondJson(" & $code & ", payload)\n").len == 0

  test "batas port di apps/api/src lolos":
    check scanSource(handler, "const defaultPort = 8080\n").len == 0
    check scanSource(handler, "const maxPort = 65535\n").len == 0

  test "nilai bisnis di apps/api/src tetap ditolak":
    check scanSource(handler, "const minAge = 17\n").len == 1
    check scanSource(handler, "let limit = 50000000\n").len == 1
    check scanSource(handler, "let rate = 0.05\n").len == 1
    check scanSource(handler, "let s = \"Rp 1.000.000\"\n").len == 1

  test "allowlist handler tidak bocor ke domain/application":
    # `200` adalah kode status HTTP di handler, tapi di domain ia bisa plafon bisnis.
    check scanSource(dom, "const maxItems = 200\n").len == 1
    check scanSource(app, "const cap = 8080\n").len == 1

suite "lint-nomagic: baseline":
  test "kunci baseline tanpa nomor baris":
    let a = scanSource(handler, "let x = 17\n")
    let b = scanSource(handler, "\n\nlet y = 17\n")
    check a.len == 1 and b.len == 1
    check baselineKey(a[0]) == baselineKey(b[0])
    check baselineKey(a[0]) == "int|" & handler & "|17"

  test "kunci memisahkan jenis temuan":
    let angka = scanSource(handler, "let x = 91\n")[0]
    let teks = scanSource(handler, "let s = \"91\"\n")[0]
    check baselineKey(angka) != baselineKey(teks)

  test "parseBaseline membuang komentar dan baris kosong":
    let entries = parseBaseline("# header\n\nint|a.nim|91\n  # komentar\nint|b.nim|7\n")
    check entries.len == 2
    check entries[0] == "int|a.nim|91"

  test "temuan terdaftar diterima":
    let v = scanSource(handler, "let x = 17\n")
    let diff = compareBaseline(v, @[baselineKey(v[0])])
    check diff.newViolations.len == 0
    check diff.staleEntries.len == 0

  test "temuan baru gagal":
    let v = scanSource(handler, "let x = 17\n")
    let diff = compareBaseline(v, @[])
    check diff.newViolations.len == 1
    check diff.staleEntries.len == 0

  test "entri yang temuannya sudah hilang gagal (baseline stale)":
    let diff = compareBaseline(@[], @["int|" & handler & "|17"])
    check diff.newViolations.len == 0
    check diff.staleEntries.len == 1

  test "renderBaseline unik dan terurut":
    let v = scanSource(handler, "let x = 17\nlet y = 17\nlet z = 31\n")
    let text = renderBaseline(v)
    check text.startsWith("#")
    let entries = parseBaseline(text)
    check entries.len == 2
    check entries[0] < entries[1]
    check entries.contains("int|" & handler & "|17")
    check entries.contains("int|" & handler & "|31")
