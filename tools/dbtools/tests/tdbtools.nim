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
  ## `check` di dalam proc pembantu **tidak** membuat uji gagal (hanya mencetak "Check failed",
  ## status uji tetap `[OK]`) — ditemukan saat uji mutasi T-035. Karena itu jalur "tidak menolak"
  ## melempar pengecualian biasa: unittest melaporkannya sebagai kegagalan uji, bukan diam-diam lolos.
  try:
    discard migrationsOf(root)
    raise newException(ValueError, "seharusnya ditolak tetapi diterima: " & root)
  except MigrateError as e:
    check e.msg.contains(needle)

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

suite "dbtools: dua tahap (contract) & rollback":
  proc writeCase(caseName, module: string, files: varargs[(string, string)]): string =
    ## Root sementara dengan beberapa berkas sekaligus (migrasi + pasangan `.down.sql`).
    let root = workRoot / caseName
    if dirExists(root):
      removeDir(root)
    createDir(root / "modules" / module / "migrations")
    for (filename, sql) in files:
      writeFile(root / "modules" / module / "migrations" / filename, sql)
    root

  proc expectPlanError(root: string, applied: seq[string], n: int, needle: string) =
    ## Sama seperti `expectMigrateError`: jalur "tidak menolak" harus melempar, supaya ujinya
    ## benar-benar gagal — bukan sekadar mencetak "Check failed".
    try:
      discard downPlan(root, migrationsOf(root), applied, n)
      raise newException(ValueError, "downPlan seharusnya menolak (n=" & $n & ") tetapi menerima")
    except MigrateError as e:
      check e.msg.contains(needle)

  test "penanda contract tercatat, dan penanda tanpa alasan ditolak":
    let root = writeCase("contract-marked", "alpha",
      ("0001_a.sql", "-- dbtools:destructive kolom lama dihapus setelah rilis 1.2\n" &
        "-- dbtools:contract kolom lama dihapus setelah rilis 1.2\n" &
        "DROP TABLE platform.alpha;\n"),
      ("0002_b.sql", "SELECT 1;\n"))
    let m = migrationsOf(root)
    check m.len == 2
    check m[0].contract
    check m[0].contractReason.contains("rilis 1.2")
    # DDL merusak tetap wajib ditandai destruktif: satu aturan, tanpa pengecualian untuk contract.
    check m[0].destructive
    check not m[1].contract

    let bad = writeCase("contract-no-reason", "alpha",
      ("0001_a.sql", "-- dbtools:contract\nSELECT 1;\n"))
    expectMigrateError(bad, "tanpa alasan")

  test "contract tanpa penanda destruktif tetap ditolak expand-only":
    let root = writeCase("contract-drop-unmarked", "alpha",
      ("0001_a.sql", "-- dbtools:contract bersihkan kolom usang\nDROP TABLE platform.alpha;\n"))
    expectMigrateError(root, "expand-only")

  test "berkas pasangan `.down.sql` bukan migrasi":
    let root = writeCase("with-down", "alpha",
      ("0001_a.sql", "SELECT 1;\n"),
      ("0001_a.down.sql", "DROP TABLE platform.alpha;\n"))
    let m = migrationsOf(root)
    check m.len == 1
    check m[0].id == "alpha/0001_a"
    check downFileOf(m[0]) == "modules/alpha/migrations/0001_a.down.sql"

  test "pendingExpand hanya migrasi expand yang belum diterapkan":
    let a = Migration(id: "a/0001_x", seq: 1, contract: false)
    let b = Migration(id: "a/0002_y", seq: 2, contract: false)
    let c = Migration(id: "a/0003_z", seq: 3, contract: true)
    check pendingExpand(@[a, b, c], @[]) == @["a/0001_x", "a/0002_y"]
    check pendingExpand(@[a, b, c], @["a/0001_x"]) == @["a/0002_y"]
    # contract tidak pernah dihitung "expand tertunda", walau belum diterapkan
    check pendingExpand(@[a, c], @["a/0001_x"]).len == 0

  test "destructivePending melewati berkas contract (bukan urusan `--up`)":
    let status = @[
      MigrationStatus(migration: Migration(id: "a/0001_drop", seq: 1, destructive: true),
        applied: false),
      MigrationStatus(migration: Migration(id: "a/0002_contract", seq: 2, destructive: true,
        contract: true), applied: false)]
    check destructivePending(status) == @["a/0001_drop"]
    check contractPending(status) == @["a/0002_contract"]
    check expandPending(status) == @["a/0001_drop"]

  test "downPlan menolak: N tidak sah, belum ada yang diterapkan, N melebihi yang diterapkan":
    let root = writeCase("down-guards", "alpha",
      ("0001_a.sql", "SELECT 1;\n"),
      ("0001_a.down.sql", "SELECT 1;\n"))
    let applied = @["alpha/0001_a"]
    expectPlanError(root, applied, 0, "harus >= 1")
    expectPlanError(root, applied, -1, "harus >= 1")
    expectPlanError(root, newSeq[string](), 1, "tidak ada migrasi yang diterapkan")
    expectPlanError(root, applied, 2, "hanya 1 yang diterapkan")

  test "downPlan menolak bila berkas pasangan tidak ada":
    let root = writeCase("down-no-pair", "alpha", ("0001_a.sql", "SELECT 1;\n"))
    expectPlanError(root, @["alpha/0001_a"], 1, "tidak ada berkas pasangan")

  test "downPlan menolak bila migrasi tercatat di DB tanpa berkasnya di disk":
    let root = writeCase("down-ghost", "alpha", ("0001_a.sql", "SELECT 1;\n"))
    expectPlanError(root, @["alpha/9999_hilang"], 1, "berkasnya tidak ada")

  test "berkas pasangan rollback diperiksa seperti migrasi, bukan SQL bebas":
    # `COMMIT` di berkas pasangan akan mematahkan janji "satu berkas = satu transaksi".
    let tx = writeCase("down-tx", "alpha",
      ("0001_a.sql", "SELECT 1;\n"),
      ("0001_a.down.sql", "SELECT 1;\nCOMMIT;\n"))
    expectPlanError(tx, @["alpha/0001_a"], 1, "mengelola transaksi")

    let kosong = writeCase("down-kosong", "alpha",
      ("0001_a.sql", "SELECT 1;\n"),
      ("0001_a.down.sql", "\n\n"))
    expectPlanError(kosong, @["alpha/0001_a"], 1, "kosong")

  test "downPlan mengurutkan pembatalan dari yang terakhir diterapkan":
    let root = writeCase("down-order", "alpha",
      ("0001_a.sql", "SELECT 1;\n"),
      ("0001_a.down.sql", "SELECT 1;\n"),
      ("0002_b.sql", "SELECT 1;\n"),
      ("0002_b.down.sql", "SELECT 1;\n"))
    # `applied` = urutan penerapan terbalik (yang terakhir diterapkan di depan).
    let applied = @["alpha/0002_b", "alpha/0001_a"]
    let plan = downPlan(root, migrationsOf(root), applied, 2)
    check plan.len == 2
    check plan[0].id == "alpha/0002_b"
    check plan[1].id == "alpha/0001_a"
    # hanya yang diminta masuk rencana
    let satu = downPlan(root, migrationsOf(root), applied, 1)
    check satu.len == 1
    check satu[0].id == "alpha/0002_b"

suite "dbtools: penjagaan seed dev (O-062)":
  test "nama basis data dibaca dari URL; kredensial, opsi, dan fragment diabaikan":
    check databaseNameOf("postgres://user:rahasia@127.0.0.1:5432/kran_dev") == "kran_dev"
    check databaseNameOf("postgres://user:p@host:5432/kran_dev?sslmode=disable") == "kran_dev"
    check databaseNameOf("postgresql://host/kran_test#x") == "kran_test"
    check databaseNameOf("postgres://host:5432/kran_dev") == "kran_dev"

  test "bentuk yang tidak dikenali -> kosong, bukan tebakan":
    check databaseNameOf("") == ""
    check databaseNameOf("kran_dev") == ""
    check databaseNameOf("postgres://host:5432") == ""
    check databaseNameOf("postgres://host:5432/") == ""
    check databaseNameOf("postgres://host:5432/a/b") == ""

  test "--dev hanya untuk _dev/_test; selain itu (termasuk tak dikenali) ditolak":
    check devSeedDbAllowed("postgres://u:p@h:5432/kran_dev")
    check devSeedDbAllowed("postgres://u:p@h:5432/kran_test")
    check not devSeedDbAllowed("postgres://u:p@h:5432/kran")
    check not devSeedDbAllowed("postgres://u:p@h:5432/kran_prod")
    check not devSeedDbAllowed("postgres://u:p@h:5432/kran_devx")
    check not devSeedDbAllowed("")
