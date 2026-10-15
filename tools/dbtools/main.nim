## dbtools — migrasi, status, validasi (spec §12.1, §21.7).
##
##   dbtools [--root <dir>] validate              # tanpa DB: urutan + pemeriksaan berkas
##   dbtools [--root <dir>] migrate [--dry-run]   # butuh KRAN_DATABASE_URL
##   dbtools [--root <dir>] status                # butuh KRAN_DATABASE_URL
##   dbtools [--root <dir>] seed [--dev]          # butuh KRAN_DATABASE_URL; --dev = seed dev/test
##
## Keluar: 0 sukses, 1 masalah data/migrasi, 2 kesalahan pemakaian.

import std/[os, strutils]
import db_connector/db_postgres

import "platform-lib/db/config"
import "platform-lib/db/pool"
import lib

proc usage() =
  stderr.writeLine("pemakaian: dbtools [--root <dir>] validate|migrate|status|seed [--dry-run] [--dev]")

var root = getCurrentDir()
var command = ""
var dryRun = false
var devSeeds = false

let args = commandLineParams()
var i = 0
while i < args.len:
  case args[i]
  of "--root":
    inc i
    if i >= args.len:
      usage()
      quit(2)
    root = absolutePath(args[i])
  of "--dry-run":
    dryRun = true
  of "--dev":
    devSeeds = true
  of "--help", "-h":
    usage()
    quit(0)
  else:
    if command.len > 0:
      stderr.writeLine("argumen tidak dikenal: " & args[i])
      usage()
      quit(2)
    command = args[i]
  inc i

if command.len == 0:
  usage()
  quit(2)
if not dirExists(root):
  stderr.writeLine("akar tidak ditemukan: " & root)
  quit(2)

proc printPlan(migra: seq[Migration]) =
  for m in migra:
    let flag = if m.destructive: " [destructive: " & m.destructiveReason & "]" else: ""
    echo "  " & align($m.seq, 5) & "  " & m.id & flag

proc runPlan() =
  for m in migrationsOf(root):
    let flag = if m.destructive: " [destructive: " & m.destructiveReason & "]" else: ""
    echo "  " & align($m.seq, 5) & "  " & m.id & flag

proc runStatus(db: DbConn): int =
  let st = reportStatus(db, root)
  var applied = 0
  var drift = false
  for s in st:
    var note = "belum"
    if s.applied:
      inc applied
      note = "sudah"
      if s.checksumChanged:
        note = "SUDAH TAPI ISI BERUBAH"
        drift = true
    echo "  " & align($s.migration.seq, 5) & "  " & s.migration.id & "  " & note
  echo "dbtools status: " & $applied & "/" & $st.len & " diterapkan"
  if drift:
    1
  else:
    0

proc runMigrate(db: DbConn): int =
  let report = applyMigrations(db, root, dryRun)
  if dryRun:
    echo "dbtools migrate (dry-run): " & $report.applied.len & " migrasi akan diterapkan"
    runPlan()
  else:
    echo "dbtools migrate: " & $report.applied.len & " diterapkan, " &
      $report.skipped.len & " dilewati (sudah ada)"
    for id in report.applied:
      echo "  + " & id
  0

proc runSeed(db: DbConn): int =
  ## Terapkan berkas seed pack (`packs/*/generated/*.sql`) + berkas dev/test bila `--dev`.
  ## Idempotent: seluruh berkas seed memakai `ON CONFLICT`, jadi aman dijalankan berulang.
  let files = seedFiles(root, devSeeds)
  if files.len == 0:
    echo "dbtools seed: tidak ada berkas seed"
    return 0
  for rel in files:
    execScript(db, readFile(root / rel))
    echo "  + " & rel
  echo "dbtools seed: " & $files.len & " berkas diterapkan" &
    (if devSeeds: " (termasuk seed dev/test)" else: "")
  0

try:
  case command
  of "validate":
    let migra = migrationsOf(root)
    let problems = validateMigrations(migra)
    if problems.len > 0:
      stderr.writeLine("dbtools validate: " & $problems.len & " masalah")
      for p in problems:
        stderr.writeLine("  - " & p)
      quit(1)
    echo "dbtools validate: " & $migra.len & " migrasi valid (expand-only)"
    runPlan()
    quit(0)

  of "migrate", "status", "seed":
    let envT = envTableFromProcess()
    if not databaseUrlSet(envT):
      stderr.writeLine("KRAN_DATABASE_URL belum diisi (lihat docs/runbooks/dev-db.md)")
      quit(2)
    let pool = newDbPool(dbConfigFromEnv(envT))
    var code = 0
    try:
      code = pool.withConn(proc(db: DbConn): int =
        case command
        of "status": runStatus(db)
        of "seed": runSeed(db)
        else: runMigrate(db))
    finally:
      pool.close()
    quit(code)
  else:
    stderr.writeLine("perintah tidak dikenal: " & command)
    usage()
    quit(2)
except MigrateError as e:
  stderr.writeLine("dbtools: migrasi tidak valid:")
  stderr.writeLine("  " & e.msg)
  quit(1)
except PoolError as e:
  stderr.writeLine("dbtools: " & e.msg)
  quit(2)
except DbError as e:
  stderr.writeLine("dbtools: kesalahan DB: " & e.msg)
  quit(1)
