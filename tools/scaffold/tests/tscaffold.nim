import std/[unittest, os, strutils]

import ../lib
import ../../archcheck/lib as archcheck

const sampleName = "sample"

proc freshTempRoot(): string =
  ## Root sementara di `$TMPDIR`; dibersihkan tiap dipanggil supaya idempotent.
  result = getTempDir() / "kran-scaffold-test"
  if dirExists(result):
    removeDir(result)
  createDir(result)

proc pathsOf(files: seq[ScaffoldFile]): seq[string] =
  for f in files:
    result.add f.path

suite "scaffold: validasi nama modul":
  test "menerima pola [a-z][a-z0-9-]*":
    for ok in ["hello", "a", "mod2", "deposit-account", "x-1-y"]:
      check isValidModuleName(ok)

  test "menolak nama tidak sah / berbahaya (path traversal)":
    for bad in ["", "Hello", "1abc", "-abc", "a b", "a_b", "a.b", "a/b", "a..b",
                "..", "../evil", "modules/../etc", "a@b"]:
      check not isValidModuleName(bad)

  test "sanitizedModuleName menukar tanda hubung jadi underscore":
    check sanitizedModuleName("deposit-account") == "deposit_account"
    check sanitizedModuleName("hello") == "hello"

suite "scaffold: renderModule":
  test "memuat berkas yang diharapkan, semuanya tidak kosong tanpa token tersisa":
    let files = renderModule(sampleName)
    let paths = pathsOf(files)
    for p in [
      "modules/sample/README.md",
      "modules/sample/MODULE.md",
      "modules/sample/api.nim",
      "modules/sample/domain/core.nim",
      "modules/sample/application/use_case.nim",
      "modules/sample/infrastructure/placeholder.nim",
      "modules/sample/interface/placeholder.nim",
      "modules/sample/migrations/0001_sample_init.sql",
      "modules/sample/seeds/params.yaml",
      "modules/sample/tests/tsample.nim",
    ]:
      check p in paths
    check files.len == 10
    for f in files:
      check f.content.len > 0
      check not f.content.contains("@") # token sudah tergantikan

  test "MODULE.md terisi sesuai §27.B (bukan placeholder kosong)":
    let files = renderModule(sampleName)
    for f in files:
      if f.path.endsWith("MODULE.md"):
        check f.content.contains("# Modul `sample`")
        check f.content.contains("## Tujuan & Bounded Context")
        check f.content.contains("## Tabel & schema")
        check f.content.contains("## Menjalankan test")
        check f.content.contains("./task test tsample")

  test "nama bertanda hubung menghasilkan nama test Nim yang sah":
    var testPath = ""
    for f in renderModule("deposit-account"):
      if f.path.startsWith("modules/deposit-account/tests/"):
        testPath = f.path
    check testPath == "modules/deposit-account/tests/tdeposit_account.nim"

  test "nama tidak sah ditolak":
    var raised = false
    try:
      discard renderModule("../evil")
    except ScaffoldError as e:
      raised = true
      check e.msg.contains("tidak sah")
    check raised

suite "scaffold: writeModule":
  test "menulis ke disk lalu menolak menimpa modul yang sudah ada":
    let root = freshTempRoot()
    let written = writeModule(root, sampleName)
    check written.len == 10
    for p in pathsOf(renderModule(sampleName)):
      check fileExists(root / p)
    check readFile(root / "modules/sample/MODULE.md").len > 0
    check readFile(root / "modules/sample/seeds/params.yaml").strip.endsWith("[]")
    var raised = false
    try:
      discard writeModule(root, sampleName)
    except ScaffoldError as e:
      raised = true
      check e.msg.contains("sudah ada")
    check raised
    removeDir(root)

  test "dry-run hanya mengembalikan rencana, tidak menulis":
    let root = freshTempRoot()
    let planned = writeModule(root, "dryrun", dryRun = true)
    check planned.len == 10
    check not dirExists(root / "modules/dryrun")
    removeDir(root)

  test "nama tidak sah ditolak sebelum ada berkas ditulis":
    let root = freshTempRoot()
    var raised = false
    try:
      discard writeModule(root, "../evil")
    except ScaffoldError:
      raised = true
    check raised
    check not dirExists(root / "modules")
    removeDir(root)

suite "scaffold: output lolos archcheck":
  test "semua .nim hasil generate bersih menurut scanSource":
    for f in renderModule(sampleName):
      if f.path.endsWith(".nim"):
        check archcheck.scanSource(f.path, f.content, ["sample"]).len == 0
