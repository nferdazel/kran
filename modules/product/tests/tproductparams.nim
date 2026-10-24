## Unit test **bentuk** atribut akrual produk (O-084, D-094, D-136).
##
## Sumber kebenaran yang diuji adalah `modules/product/seeds/params.yaml` itu sendiri, divalidasi
## lewat validator runtime (`platform/domain/param.validateAgainstSchema`) — bukan menyalin batasnya
## di dalam test (salinan akan lolos walau YAML-nya berubah). Yang dijaga di sini **hanya bentuk**
## (tipe/batas/enum); **nilai** rate/basis/skala/posting tetap menunggu compliance
## (`NEEDS-COMPLIANCE-REVIEW`) dan sengaja tidak diuji.

import std/[json, strutils, tables, unittest]
import yaml/tojson

import kernel/[rate, result]
import platform/domain/param

const seedsPath = "modules/product/seeds/params.yaml"

proc loadDefs(): Table[string, JsonNode] =
  ## Katalog seed sebagai peta key → definisi (bentuk yang sama dibaca `tools/paramgen`).
  let nodes = loadToJson(readFile(seedsPath))
  result = initTable[string, JsonNode]()
  for entry in nodes[0].items:
    result[entry["key"].getStr()] = entry

proc schemaOf(defs: Table[string, JsonNode], key: string): JsonNode =
  defs[key]["schema"]

proc strList(n: JsonNode): seq[string] =
  for e in n.items: result.add e.getStr()

suite "product: bentuk atribut akrual (O-084, D-136)":
  let defs = loadDefs()

  test "rounding_scale: integer 0..moneyScale(2)":
    let s = schemaOf(defs, "product.savings.rounding_scale")
    check s["type"].getStr() == "integer"
    check s["minimum"].getInt() == 0
    check s["maximum"].getInt() == 2
    # nilai sah
    check validateAgainstSchema(s, %0) == ""
    check validateAgainstSchema(s, %1) == ""
    check validateAgainstSchema(s, %2) == ""
    # nilai tak sah: di atas skala simpan, negatif, dan pecahan
    check validateAgainstSchema(s, %3).contains("maximum")
    check validateAgainstSchema(s, %999).contains("maximum")
    check validateAgainstSchema(s, newJInt(-1)).contains("minimum")
    check validateAgainstSchema(s, %2.5).contains("tipe")

  test "rounding_mode: hanya HALF_EVEN (yang bisa diimplementasikan kernel)":
    let s = schemaOf(defs, "product.savings.rounding_mode")
    check strList(s["enum"]) == @["HALF_EVEN"]
    check validateAgainstSchema(s, %"HALF_EVEN") == ""
    check validateAgainstSchema(s, %"HALF_UP").contains("enum")
    check validateAgainstSchema(s, %"ROUND_DOWN").contains("enum")

  test "day_count_basis: basis bernama spec §10.5":
    let s = schemaOf(defs, "product.savings.day_count_basis")
    check strList(s["enum"]) == @["ACT_365", "ACT_360", "THIRTY_360"]
    check validateAgainstSchema(s, %"ACT_365") == ""
    check validateAgainstSchema(s, %"ACT_ACT").contains("enum")

  test "interest_posting: domain nilai sengaja dibuka (bukan enum)":
    check defs["product.savings.interest_posting"]["type"].getStr() == "string"
    check not defs["product.savings.interest_posting"].hasKey("enum")
    let s = schemaOf(defs, "product.savings.interest_posting")
    check not s.hasKey("enum")
    check validateAgainstSchema(s, %"MONTH_END") == ""
    check validateAgainstSchema(s, %"DAILY") == ""

  test "interest_rate: presisi persen ditegakkan kernel, bukan schema":
    check defs["product.savings.interest_rate"]["type"].getStr() == "rate"
    let s = schemaOf(defs, "product.savings.interest_rate")
    # Belum ada batas nilai rate di schema (menunggu compliance); hanya backstop panjang.
    check not s.hasKey("minimum")
    check not s.hasKey("maximum")
    # Rate tetap 1e-6 (D-136): ≤4 desimal persen diterima, lebih dari itu ditolak (bukan dibulatkan).
    check not coerceTo[Rate]("product.savings.interest_rate", %"12.3456").isErr
    check coerceTo[Rate]("product.savings.interest_rate", %"12.12345").isErr

  test "kelimanya tetap tanpa nilai (NEEDS-COMPLIANCE-REVIEW)":
    const keys = ["product.savings.interest_rate", "product.savings.day_count_basis",
                  "product.savings.rounding_mode", "product.savings.rounding_scale",
                  "product.savings.interest_posting"]
    for k in keys:
      check defs[k]["provenance"]["class"].getStr() == "regulasi-tidak-disemai"
      check defs[k]["provenance"]["compliance"].getStr() == "NEEDS-COMPLIANCE-REVIEW"
      check not defs[k].hasKey("default_pack")
