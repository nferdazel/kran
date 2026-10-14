import std/[unittest, os, strutils]

import ../lib

const cleanRoot = "tools/dbtools/tests/fixtures/clean"
const workRoot = ".build/dbtools-test"

proc writeMigration(caseName, module, filename, sql: string): string =
  ## Membuat root sementara `.build/dbtools-test/<case>/` berisi satu migrasi.
  let root = workRoot / caseName
  if dirExists(root):
    removeDir(root)
  createDir(root / "modules" / module / "migrations")
  writeFile(root / "modules" / module / "migrations" / filename, sql)
  root

proc expectMigrateError(root: string, needle: string) =
  var raised = false
  try:
    discard migrationsOf(root)
  except MigrateError as e:
    raised = true
    check e.msg.contains(needle)
  check raised

suite "dbtools: penemuan & urutan":
  test "urut global (seq, module, filename)":
    let migra = migrationsOf(cleanRoot)
    check migra.len == 3
    check migra[0].id == "alpha/0001_create_alpha"
    check migra[1].id == "beta/0002_create_beta"
    check migra[2].id == "alpha/0003_alpha_add_note"
    check migra[0].seq == 1
    check migra[2].seq == 3
    check migra[0].module == "alpha"
    check migra[0].filename == "modules/alpha/migrations/0001_create_alpha.sql"
    check migra[0].sql.contains("platform.alpha")
    check not migra[0].destructive

  test "modul tanpa folder migrations dilewati":
    let root = workRoot / "no-migrations"
    if dirExists(root):
      removeDir(root)
    createDir(root / "modules" / "kosong")
    createDir(root / "modules" / "alpha" / "migrations")
    writeFile(root / "modules" / "alpha" / "migrations" / "0001_a.sql", "SELECT 1;")
    let migra = migrationsOf(root)
    check migra.len == 1

  test "tanpa folder modules -> daftar kosong (bukan error)":
    let root = workRoot / "empty-root"
    if dirExists(root):
      removeDir(root)
    createDir(root)
    check migrationsOf(root).len == 0

  test "validateMigrations menandai id duplikat":
    let a = Migration(id: "x/0001_a", module: "x", filename: "modules/x/migrations/0001_a.sql",
                      seq: 1, sql: "SELECT 1;")
    check validateMigrations(@[a, a]).len == 1
    check validateMigrations(@[a]).len == 0

suite "dbtools: berkas seed":
  test "generated lebih dulu, seed tulis-tangan hanya bila --dev":
    let root = workRoot / "seed-order"
    if dirExists(root):
      removeDir(root)
    createDir(root / "packs" / "base" / "generated")
    createDir(root / "packs" / "base" / "seed")
    writeFile(root / "packs" / "base" / "generated" / "param_values.sql", "SELECT 1;")
    writeFile(root / "packs" / "base" / "generated" / "param_definitions.sql", "SELECT 1;")
    writeFile(root / "packs" / "base" / "seed" / "0001_dev_users.sql", "SELECT 1;")

    check seedFiles(root) == @[
      "packs/base/generated/param_definitions.sql",
      "packs/base/generated/param_values.sql"]
    check seedFiles(root, dev = true) == @[
      "packs/base/generated/param_definitions.sql",
      "packs/base/generated/param_values.sql",
      "packs/base/seed/0001_dev_users.sql"]

  test "pack tanpa folder generated/seed tidak membuat error":
    let root = workRoot / "seed-kosong"
    if dirExists(root):
      removeDir(root)
    createDir(root / "packs" / "kosong")
    check seedFiles(root, dev = true).len == 0

  test "root tanpa folder packs -> daftar kosong":
    let root = workRoot / "seed-tanpa-packs"
    if dirExists(root):
      removeDir(root)
    createDir(root)
    check seedFiles(root, dev = true).len == 0

suite "dbtools: pembersihan komentar & literal":
  test "komentar baris & blok dibuang":
    check stripSqlComments("SELECT 1; -- drop table x\n").contains("SELECT 1;")
    check not stripSqlComments("SELECT 1; -- drop table x\n").contains("drop table")
    check not stripSqlComments("/* drop table y */ SELECT 2;").contains("drop table")

  test "komentar di dalam string tetap (bukan komentar)":
    let kept = stripSqlComments("SELECT '-- bukan komentar';")
    check kept.contains("'-- bukan komentar'")

  test "isi literal dibuang untuk pemindaian DDL":
    check not stripSqlLiterals("INSERT INTO t VALUES ('drop table sekolah');")
      .contains("drop table")
    check stripSqlLiterals("SELECT 'a''b';").contains("a''b") == false

  test "nama identifier yang memuat kata terlarang tidak memicu":
    check destructiveStatements(
      "CREATE TRIGGER audit_log_no_truncate BEFORE TRUNCATE ON platform.audit_log " &
      "FOR EACH STATEMENT EXECUTE FUNCTION platform.f();").len == 0

  test "DDL merusak terdeteksi pada awal kalimat & di dalam ALTER TABLE":
    check destructiveStatements("DROP TABLE platform.x;").len == 1
    check destructiveStatements("DROP INDEX platform.i;").len == 1
    check destructiveStatements("TRUNCATE platform.x;").len == 1
    check destructiveStatements("ALTER TABLE platform.x DROP COLUMN y;").len == 1
    check destructiveStatements("ALTER TABLE platform.x RENAME COLUMN a TO b;").len == 1
    check destructiveStatements("ALTER TABLE platform.x ADD COLUMN y text;").len == 0
    check destructiveStatements("ALTER TABLE platform.x ALTER COLUMN y SET DEFAULT 1;").len == 0

suite "dbtools: penjaga expand-only":
  test "DDL merusak tanpa penanda ditolak":
    let root = writeMigration("drop-unmarked", "alpha", "0001_drop.sql",
      "DROP TABLE platform.alpha;\n")
    expectMigrateError(root, "expand-only")

  test "penanda dengan alasan diterima dan tercatat":
    let root = writeMigration("drop-marked", "alpha", "0001_drop.sql",
      "-- dbtools:destructive kolom usang, sudah tidak dipakai sejak 2026-10\n" &
      "DROP TABLE platform.alpha;\n")
    let m = migrationsOf(root)
    check m.len == 1
    check m[0].destructive
    check m[0].destructiveReason.len > 0

  test "penanda tanpa alasan ditolak":
    let root = writeMigration("drop-no-reason", "alpha", "0001_drop.sql",
      "-- dbtools:destructive\nDROP TABLE platform.alpha;\n")
    expectMigrateError(root, "tanpa alasan")

  test "BEGIN/COMMIT di berkas migrasi ditolak":
    let root = writeMigration("tx", "alpha", "0001_tx.sql",
      "BEGIN;\nCREATE TABLE platform.x (id uuid);\nCOMMIT;\n")
    expectMigrateError(root, "mengelola transaksi")

  test "nama berkas tanpa awalan urutan ditolak":
    let root = writeMigration("badname", "alpha", "createalpha.sql", "SELECT 1;")
    expectMigrateError(root, "NNNN")
    let root2 = writeMigration("badprefix", "alpha", "0001x_create.sql", "SELECT 1;")
    expectMigrateError(root2, "angka")

  test "berkas migrasi kosong ditolak":
    let root = writeMigration("empty", "alpha", "0001_kosong.sql", "\n\n")
    expectMigrateError(root, "kosong")
