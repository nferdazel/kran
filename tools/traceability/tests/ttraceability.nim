## Unit test gate traceability (T-180): yang diuji adalah **aturan gate**, bukan isi register repo.
##
## Register palsu ditulis ke `.build/` supaya test ini gagal bila gate kembali menjadi hijau-palsu
## (mis. berhenti mencocokkan nama test, atau berhenti memeriksa parameter).

import std/[os, sequtils, strutils, unittest]

import ../lib

const workRoot = ".build/traceability-test"

proc putFile(path, content: string) =
  createDir(parentDir(path))
  writeFile(path, content)

proc freshRoot(): string =
  if dirExists(workRoot):
    removeDir(workRoot)
  createDir(workRoot)
  putFile(workRoot / "modules" / "demo" / "seeds" / "params.yaml",
    "- key: demo.rate\n  type: json\n  scopes: [GLOBAL]\n  schema: { type: array }\n" &
    "  sensitivity: NORMAL\n  provenance:\n    class: kebijakan\n" &
    "  default_pack: { base: \"1\" }\n")
  putFile(workRoot / "apps" / "api" / "tests" / "itdemo.nim",
    "suite \"demo\":\n  test \"tarif dipakai\":\n    check true\n")
  workRoot

proc req(id, status: string; params: seq[string]; tests: seq[TestRef]): Requirement =
  Requirement(id: id, title: id, status: status, params: params, tests: tests)

proc messages(problems: seq[TraceProblem]): string =
  problems.mapIt(it.message).join(" | ")

suite "traceability: aturan gate":
  test "requirement aktif dengan parameter + test yang ada = lolos":
    let root = freshRoot()
    let problems = validate(root, Register(requirements: @[
      req("REG-001", "active", @["demo.rate"],
        @[TestRef(file: "apps/api/tests/itdemo.nim", name: "tarif dipakai")])]))
    check problems.len == 0

  test "requirement aktif tanpa kontrol ditolak":
    let root = freshRoot()
    let problems = validate(root, Register(requirements: @[
      req("REG-002", "active", @[],
        @[TestRef(file: "apps/api/tests/itdemo.nim", name: "tarif dipakai")])]))
    check problems.len == 1
    check messages(problems).contains("tanpa kontrol")

  test "requirement aktif tanpa test ditolak":
    let root = freshRoot()
    let problems = validate(root, Register(requirements: @[
      req("REG-003", "active", @["demo.rate"], @[])]))
    check problems.len == 1
    check messages(problems).contains("tanpa test")

  test "parameter yang tidak ada di seeds ditolak":
    let root = freshRoot()
    let problems = validate(root, Register(requirements: @[
      req("REG-004", "active", @["demo.tidak_ada"],
        @[TestRef(file: "apps/api/tests/itdemo.nim", name: "tarif dipakai")])]))
    check problems.len == 1
    check messages(problems).contains("tidak ada di seeds/params.yaml")

  test "nama test harus benar-benar ada, bukan hanya berkasnya":
    let root = freshRoot()
    let problems = validate(root, Register(requirements: @[
      req("REG-005", "active", @["demo.rate"],
        @[TestRef(file: "apps/api/tests/itdemo.nim", name: "test yang sudah dihapus")])]))
    check problems.len == 1
    check messages(problems).contains("test tidak ditemukan")

  test "berkas test yang hilang ditolak":
    let root = freshRoot()
    let problems = validate(root, Register(requirements: @[
      req("REG-006", "active", @["demo.rate"],
        @[TestRef(file: "apps/api/tests/itghost.nim", name: "apa saja")])]))
    check problems.len == 1
    check messages(problems).contains("berkas test tidak ada")

  test "deferred tidak divalidasi isinya":
    let root = freshRoot()
    let problems = validate(root, Register(requirements: @[req("REG-007", "deferred", @[], @[])]))
    check problems.len == 0

  test "register dengan id duplikat / status tak dikenal ditolak saat dibaca":
    let root = freshRoot()
    let path = workRoot / "register.yaml"
    putFile(path, """
version: 1
requirements:
  - id: REG-008
    status: active
    controls: { params: [demo.rate] }
    tests: [{ file: apps/api/tests/itdemo.nim, name: "tarif dipakai" }]
  - id: REG-008
    status: aktif
""")
    let register = loadRegister(path)
    check register.problems.len == 2
    check register.problems.mapIt(it.message).join(" | ").contains("duplikat")
    check register.problems.mapIt(it.message).join(" | ").contains("status")
    # Id duplikat tetap satu-satunya temuan baca; isi requirement pertama valid.
    check validate(root, register).len == 0
