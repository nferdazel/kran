## Runner migrasi SQL + penjaga pola **expand-only** (spec §9.1(11), §21.7).
##
## Desain:
##   - Migrasi = berkas SQL murni di `modules/<m>/migrations/<NNNN>_<slug>.sql`.
##     Urutan global: `(NNNN, nama modul, nama berkas)` — deterministik. Modul yang butuh
##     schema modul lain memakai nomor lebih besar.
##   - Satu berkas = satu transaksi. Berkas **tidak boleh** memuat BEGIN/COMMIT/ROLLBACK.
##   - **Idempotent**: berkas yang sudah tercatat di `platform.schema_migration` dilewati;
##     menjalankan `migrate` dua kali aman.
##   - **Anti-drift**: berkas yang sudah diterapkan tidak boleh berubah isinya (checksum
##     SHA-256 dihitung oleh `pgcrypto` di DB, bukan implementasi sendiri).
##   - **Expand-only**: DDL merusak (`DROP TABLE/COLUMN/SCHEMA/CONSTRAINT`, `TRUNCATE`,
##     `RENAME COLUMN`) ditolak kecuali berkas menandai alasannya di header:
##         `-- dbtools:destructive <alasan>`
##     (pola *expand/contract*: hapus kolom = migrasi kontrak tersendiri, sengaja eksplisit.)
##   - Seluruh berkas divalidasi **sebelum** ada yang diterapkan: satu berkas salah → tidak
##     ada perubahan sama sekali.

import std/[os, strutils, algorithm, tables, times]

import db_connector/[db_postgres, postgres]

type
  MigrateError* = object of ValueError

  Migration* = object
    id*: string       ## `<module>/<basename>` — kunci di `platform.schema_migration`
    module*: string
    filename*: string ## relatif terhadap akar repo
    seq*: int
    sql*: string
    destructive*: bool
    destructiveReason*: string

  MigrateReport* = object
    applied*: seq[string]
    skipped*: seq[string]
    total*: int

  MigrationStatus* = object
    migration*: Migration
    applied*: bool
    checksumChanged*: bool
    appliedSha256*: string

const
  bootstrapSql* = """
CREATE SCHEMA IF NOT EXISTS platform;
CREATE TABLE IF NOT EXISTS platform.schema_migration (
  migration_id text PRIMARY KEY,
  module       text NOT NULL,
  filename     text NOT NULL,
  seq          int  NOT NULL,
  sha256       text NOT NULL,
  destructive  boolean NOT NULL DEFAULT false,
  applied_at   timestamptz NOT NULL DEFAULT now(),
  duration_ms  int NOT NULL DEFAULT 0
);"""

  destructivePrefixes* = ["drop ", "truncate"]
  destructiveInAlter* = [" drop column", " drop constraint", " rename "]

  txMarkers* = ["begin", "commit", "rollback"]

proc fail(msg: string) {.noreturn.} =
  raise newException(MigrateError, msg)

proc stripSqlComments*(sql: string): string =
  ## Buang komentar `-- …` dan `/* … */` supaya kata kunci di komentar tidak memicu
  ## pemeriksaan (dan tidak menyembunyikan DDL nyata).
  var i = 0
  var inBlock = false
  var inLine = false
  var inString = false
  while i < sql.len:
    let c = sql[i]
    if inLine:
      if c == '\n':
        inLine = false
        result.add c
      inc i
      continue
    if inBlock:
      if c == '*' and i + 1 < sql.len and sql[i + 1] == '/':
        inBlock = false
        inc i
      inc i
      continue
    if inString:
      result.add c
      if c == '\'':
        inString = false
      inc i
      continue
    if c == '\'':
      inString = true
      result.add c
      inc i
      continue
    if c == '-' and i + 1 < sql.len and sql[i + 1] == '-':
      inLine = true
      inc i
      inc i
      continue
    if c == '/' and i + 1 < sql.len and sql[i + 1] == '*':
      inBlock = true
      inc i
      inc i
      continue
    result.add c
    inc i

proc stripSqlLiterals*(sql: string): string =
  ## Buang isi literal `'…'` supaya teks di dalam string tidak memicu pemeriksaan DDL.
  var i = 0
  var inString = false
  while i < sql.len:
    let c = sql[i]
    if inString:
      if c == '\'':
        if i + 1 < sql.len and sql[i + 1] == '\'':
          result.add "'"
          inc i
          inc i
          continue
        inString = false
        result.add '\''
      inc i
      continue
    if c == '\'':
      inString = true
      result.add '\''
      inc i
      continue
    result.add c
    inc i

proc destructiveStatements*(sql: string): seq[string] =
  ## Kalimat yang merusak. Di-anchor pada **awal kalimat** supaya identifier seperti
  ## `audit_log_no_truncate` tidak salah tertangkap.
  let code = stripSqlLiterals(stripSqlComments(sql)).toLowerAscii()
  for raw in code.split(';'):
    let stmt = raw.strip()
    if stmt.len == 0:
      continue
    var bad = false
    for p in destructivePrefixes:
      if stmt.startsWith(p):
        bad = true
    if not bad and stmt.startsWith("alter table"):
      for p in destructiveInAlter:
        if stmt.contains(p):
          bad = true
    if bad:
      result.add stmt[0 ..< min(70, stmt.len)]

proc parseSeq(filename: string): int =
  ## `<NNNN>_<slug>.sql` → NNNN.
  let base = extractFilename(filename)
  let underscore = base.find('_')
  if underscore <= 0:
    fail("nama migrasi harus `<NNNN>_<slug>.sql`: " & filename)
  let digits = base[0 ..< underscore]
  if digits.len < 2 or digits.len > 6:
    fail("awalan urutan migrasi harus 2–6 digit: " & filename)
  for c in digits:
    if c notin {'0' .. '9'}:
      fail("awalan urutan migrasi harus angka: " & filename)
  parseInt(digits)

proc readMigration*(root, relPath, module: string): Migration =
  var m = Migration(module: module, filename: relPath)
  m.seq = parseSeq(relPath)
  let base = extractFilename(relPath)
  m.id = module & "/" & base[0 ..< base.len - len(".sql")]
  try:
    m.sql = readFile(root / relPath)
  except CatchableError as e:
    fail("tidak bisa membaca " & relPath & ": " & e.msg)
  if m.sql.strip().len == 0:
    fail(relPath & ": berkas migrasi kosong")

  # header diperiksa dari komentar asli, jadi pakai `m.sql` mentah.
  for line in m.sql.splitLines():
    let t = line.strip()
    if t.startsWith("-- dbtools:destructive"):
      m.destructiveReason = t[len("-- dbtools:destructive") .. ^1].strip()
      if m.destructiveReason.len == 0:
        fail(relPath & ": `-- dbtools:destructive` tanpa alasan")
      m.destructive = true

  let found = destructiveStatements(m.sql)
  if found.len > 0:
    if not m.destructive:
      fail(relPath & ": DDL merusak ditolak oleh mode expand-only (" & found[0] &
        "). Pola expand/contract: jalankan perubahan lewat migrasi baru; bila memang " &
        "disengaja, tandai header `-- dbtools:destructive <alasan>`")
    m.destructive = true

  let code = stripSqlComments(m.sql).toLowerAscii()
  for stmt in code.split(';'):
    let s = stmt.strip()
    for marker in txMarkers:
      if s == marker or s.startsWith(marker & " "):
        fail(relPath & ": berkas migrasi tidak boleh memuat `" & marker.toUpperAscii() &
          "` — runner yang mengelola transaksi")
  m

proc migrationsOf*(root: string): seq[Migration] =
  ## Semua modul, urut `(seq, module, filename)`.
  let modulesDir = root / "modules"
  if not dirExists(modulesDir):
    return @[]
  var modules: seq[string]
  for kind, path in walkDir(modulesDir):
    if kind in {pcDir, pcLinkToDir}:
      modules.add extractFilename(path)
  modules.sort()
  for module in modules:
    let dir = modulesDir / module / "migrations"
    if not dirExists(dir):
      continue
    var files: seq[string]
    for kind, path in walkDir(dir):
      if kind in {pcFile, pcLinkToFile} and path.endsWith(".sql"):
        files.add extractFilename(path)
    files.sort()
    for f in files:
      result.add readMigration(root, "modules/" & module & "/migrations/" & f, module)
  result.sort(proc(a, b: Migration): int =
    result = cmp(a.seq, b.seq)
    if result == 0:
      result = cmp(a.module, b.module)
    if result == 0:
      result = cmp(a.filename, b.filename))

proc seedFiles*(root: string, dev = false): seq[string] =
  ## Berkas seed yang diterapkan `dbtools seed`, relatif terhadap `root`.
  ##
  ## Urutan: untuk setiap pack (abjad) — `generated/*.sql` lebih dulu (definisi parameter sebelum
  ## nilai), lalu `seed/*.sql` **hanya bila** `dev`. `generated/` = keluaran `paramgen` (jangan
  ## diedit manusia); `seed/` = berkas tulis-tangan untuk dev/test (mis. pengguna sintetis) yang
  ## tidak dipakai produksi.
  for pack in walkDir(root / "packs"):
    if pack.kind != pcDir:
      continue
    var generated: seq[string]
    var devSeeds: seq[string]
    if dirExists(pack.path / "generated"):
      for entry in walkDir(pack.path / "generated"):
        if entry.kind == pcFile and entry.path.endsWith(".sql"):
          generated.add relativePath(entry.path, root)
    if dev and dirExists(pack.path / "seed"):
      for entry in walkDir(pack.path / "seed"):
        if entry.kind == pcFile and entry.path.endsWith(".sql"):
          devSeeds.add relativePath(entry.path, root)
    generated.sort()
    devSeeds.sort()
    result.add generated
    result.add devSeeds

proc validateMigrations*(migra: seq[Migration]): seq[string] =
  ## Temuan yang membuat seluruh run dibatalkan (dijalankan tanpa DB).
  var seen: seq[string]
  for m in migra:
    if m.id in seen:
      result.add "id migrasi duplikat: " & m.id
    seen.add m.id

proc sha256Of*(db: DbConn, text: string): string =
  ## pgcrypto di DB yang menghitung — tidak ada implementasi hash sendiri.
  db.getValue(sql"SELECT encode(digest(?::text, 'sha256'), 'hex')", text)

proc execScript*(db: DbConn, script: string) =
  ## Menjalankan skrip SQL **multi-pernyataan** (perilaku seperti `psql`). `db_postgres.exec`
  ## selalu memakai `PQexecParams` yang menolak lebih dari satu pernyataan, sementara berkas
  ## migrasi memuat banyak pernyataan (termasuk badan fungsi PL/pgSQL).
  let res = pqexec(db, script.cstring)
  if res.isNil:
    raise newException(DbError, "gagal menjalankan skrip: " & $pqerrorMessage(db))
  let status = pqresultStatus(res)
  if status != PGRES_COMMAND_OK and status != PGRES_TUPLES_OK:
    var msg = ($pqresultErrorMessage(res)).strip()
    if msg.len == 0:
      msg = ($pqerrorMessage(db)).strip()
    pqclear(res)
    if msg.len == 0:
      msg = "pernyataan SQL gagal tanpa pesan dari server"
    raise newException(DbError, msg)
  pqclear(res)

proc ensureBootstrap*(db: DbConn) =
  execScript(db, bootstrapSql)

proc appliedChecksums*(db: DbConn): seq[(string, string)] =
  for row in db.getAllRows(sql"SELECT migration_id, sha256 FROM platform.schema_migration"):
    result.add (row[0], row[1])

proc reportStatus*(db: DbConn, root: string): seq[MigrationStatus] =
  let migra = migrationsOf(root)
  var known = initTable[string, string]()
  for (mid, sha) in appliedChecksums(db):
    known[mid] = sha
  for m in migra:
    var s = MigrationStatus(migration: m)
    if known.hasKey(m.id):
      s.applied = true
      s.appliedSha256 = known[m.id]
      s.checksumChanged = s.appliedSha256 != sha256Of(db, m.sql)
    result.add s

proc applyMigrations*(db: DbConn, root: string, dryRun = false): MigrateReport =
  ## Terapkan semua migrasi yang belum tercatat. Raise `MigrateError` bila ada masalah.
  let migra = migrationsOf(root)
  let problems = validateMigrations(migra)
  if problems.len > 0:
    fail("migrasi tidak valid:\n  - " & problems.join("\n  - "))
  result.total = migra.len

  if dryRun:
    for m in migra:
      result.applied.add m.id
    return

  ensureBootstrap(db)
  # `db_postgres.exec` hanya menerima status COMMAND_OK, jadi SELECT kunci memakai getValue.
  discard db.getValue(sql"SELECT pg_advisory_lock(hashtext('kran.dbtools.migrate'))")
  try:
    var known = initTable[string, string]()
    var appliedSha = initTable[string, string]()
    for (mid, sha) in appliedChecksums(db):
      known[mid] = sha
    for m in migra:
      let sha = sha256Of(db, m.sql)
      if known.hasKey(m.id):
        appliedSha[m.id] = known[m.id]
        if known[m.id] != sha:
          fail(m.filename & ": migrasi sudah diterapkan tetapi isinya berubah" &
            " (checksum " & known[m.id][0 ..< 12] & " → " & sha[0 ..< 12] &
            "). Buat migrasi baru, jangan mengubah yang sudah jalan.")
        result.skipped.add m.id
        continue
      let start = epochTime()
      db.exec(sql"BEGIN")
      try:
        try:
          execScript(db, m.sql)
        except DbError as e:
          raise newException(DbError, m.filename & ": " & e.msg)
        db.exec(sql"""INSERT INTO platform.schema_migration
                        (migration_id, module, filename, seq, sha256, destructive, duration_ms)
                      VALUES (?, ?, ?, ?, ?, ?, ?)""",
                m.id, m.module, m.filename, $m.seq, sha, $m.destructive,
                $(int((epochTime() - start) * 1000)))
        db.exec(sql"COMMIT")
      except CatchableError:
        db.exec(sql"ROLLBACK")
        raise
      result.applied.add m.id
  finally:
    discard db.getValue(sql"SELECT pg_advisory_unlock(hashtext('kran.dbtools.migrate'))")
