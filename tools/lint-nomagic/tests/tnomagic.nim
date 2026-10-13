import std/unittest
import std/strutils

import ../lib

const
  dom = "modules/lending/domain/collectibility.nim"
  app = "modules/lending/application/accrue.nim"

suite "lint-nomagic: cakupan pemindaian":
  test "hanya modules/*/domain|application":
    check isScanned(dom)
    check isScanned(app)
    check not isScanned("modules/lending/infrastructure/pg.nim")
    check not isScanned("modules/lending/tests/tx.nim")
    check not isScanned("shared/kernel/money.nim")
    check not isScanned("shared/kernel/generated/paramkeys.nim")
    check not isScanned("tools/paramgen/main.nim")
    check not isScanned("apps/api/src/main.nim")

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
