## Bootstrap config koneksi DB (spec §12.5).
##
## Isi modul ini hanya **konfigurasi koneksi** (host/port/db/user/password, ukuran pool,
## timeout). **Tidak ada nilai bisnis** di sini — rate, limit, ambang, fee selalu dari
## parameter DB (spec §10).
##
## Sumber: variabel lingkungan.
##
##   KRAN_DATABASE_URL              URL `postgres://user:pass@host:port/db`   (wajib untuk fitur DB)
##   KRAN_DB_POOL_SIZE              jumlah maksimum koneksi (default 8)
##   KRAN_DB_ACQUIRE_TIMEOUT_MS     batas tunggu ambil koneksi (default 5000)
##   KRAN_DB_CONNECT_TIMEOUT_MS     batas membuka koneksi baru (default 5000; libpq minimum 2 s)
##   KRAN_DB_STATEMENT_TIMEOUT_MS   statement_timeout libpq (default 15000)
##   KRAN_DB_QUERY_DEADLINE_MS      batas satu blok kerja `withConn`/`withTx` (default
##                                  statement_timeout + 5000; wajib > statement_timeout)
##   KRAN_DB_VALIDATE_ON_ACQUIRE    `1`/`0` — cek `PQstatus` saat ambil koneksi (default 1)
##
## `KRAN_DB_QUERY_DEADLINE_MS` menutup kasus koneksi yang membeku di tengah kueri (perantara yang
## tetap meng-ACK, jadi keepalive tidak memicu). Satuannya **blok kerja**, sedangkan
## `statement_timeout` berlaku **per statement**: blok `withTx` yang berisi banyak statement bisa
## memakai seluruh anggaran (mis. 20 s), jadi blok sah yang totalnya melebihi anggaran akan gagal.
## Nilai eksplisit wajib > `statement_timeout` supaya satu statement sah tidak dibunuh lebih dulu.
## Koneksi yang diambil langsung lewat `pool.acquire()` (mis. pump LISTEN yang hidup lama) tidak
## memakai anggaran ini — lihat `docs/ACCEPTED-LIMITS.md`.
##
## Batas yang diketahui (jujur): parser URL hanya menerima bentuk di atas, **tanpa parameter
## kueri** dan **tanpa sslmode**. Koneksi dibuka lewat `PQconnectdb(conninfo)` (`pool.nim`), jadi
## `sslmode` sebenarnya bisa ditambahkan nanti lewat conninfo — sampai sekarang belum dibutuhkan
## karena deployment Fase 0 berjalan di host yang sama (koneksi lokal). Bila kebutuhan TLS/mTLS
## muncul, itu keputusan ADR tersendiri, bukan tambalan di sini.

import std/[os, strutils, tables, uri]

type
  ConfigError* = object of ValueError

  DbTarget* = object
    host*: string
    port*: string
    database*: string
    user*: string
    password*: string
    options*: string ## diteruskan apa adanya ke libpq `options` (mis. `-c statement_timeout=15000`)

  DbConfig* = object
    target*: DbTarget
    poolSize*: int
    acquireTimeoutMs*: int
    connectTimeoutMs*: int
    statementTimeoutMs*: int
    queryDeadlineMs*: int
    validateOnAcquire*: bool

const
  defaultPoolSize* = 8
  defaultAcquireTimeoutMs* = 5_000
  defaultConnectTimeoutMs* = 5_000
  defaultStatementTimeoutMs* = 15_000
  defaultQueryDeadlineMarginMs* = 5_000

proc fail(msg: string) {.noreturn.} =
  raise newException(ConfigError, msg)

proc parseDatabaseUrl*(url: string): DbTarget =
  ## Menerima `postgres://user:password@host:port/database`.
  ## Password di-*percent-decode* supaya aman memakai karakter URL-reserved.
  let u = url.strip()
  if u.len == 0:
    fail("KRAN_DATABASE_URL kosong")
  var rest = ""
  if u.startsWith("postgres://"):
    rest = u[len("postgres://") .. ^1]
  elif u.startsWith("postgresql://"):
    rest = u[len("postgresql://") .. ^1]
  else:
    fail("KRAN_DATABASE_URL harus berawalan postgres:// atau postgresql:// (dapat: " &
      u[0 ..< min(12, u.len)] & "...)")

  if rest.contains('?'):
    fail("parameter kueri pada KRAN_DATABASE_URL belum didukung (lihat dokumentasi modul ini)")

  let slash = rest.find('/')
  if slash < 0:
    fail("KRAN_DATABASE_URL tidak memuat nama database (…/namadb)")
  let authority = rest[0 ..< slash]
  let dbname = rest[slash + 1 .. ^1]
  if dbname.len == 0 or dbname.contains('/'):
    fail("nama database pada KRAN_DATABASE_URL tidak valid")

  var creds = ""
  var hostport = authority
  let at = authority.rfind('@')
  if at >= 0:
    creds = authority[0 ..< at]
    hostport = authority[at + 1 .. ^1]

  if hostport.len == 0:
    fail("host pada KRAN_DATABASE_URL tidak boleh kosong")

  result = DbTarget(database: dbname, host: hostport, port: "")
  let colon = hostport.rfind(':')
  if colon >= 0:
    result.host = hostport[0 ..< colon]
    result.port = hostport[colon + 1 .. ^1]
    if result.port.len == 0:
      fail("port pada KRAN_DATABASE_URL kosong")

  if creds.len > 0:
    let sep = creds.find(':')
    if sep >= 0:
      result.user = decodeUrl(creds[0 ..< sep], decodePlus = false)
      result.password = decodeUrl(creds[sep + 1 .. ^1], decodePlus = false)
    else:
      result.user = decodeUrl(creds, decodePlus = false)

proc parsePositiveInt(env: Table[string, string], key: string, default: int): int =
  let raw = env.getOrDefault(key, "").strip()
  if raw.len == 0:
    return default
  var v = 0
  try:
    v = parseInt(raw)
  except ValueError:
    fail(key & " harus bilangan bulat (dapat: " & raw & ")")
  if v <= 0:
    fail(key & " harus > 0 (dapat: " & raw & ")")
  v

proc parseBool(env: Table[string, string], key: string, default: bool): bool =
  case env.getOrDefault(key, "").strip().toLowerAscii()
  of "": default
  of "1", "true", "yes", "on": true
  of "0", "false", "no", "off": false
  else:
    fail(key & " harus 1/0 (dapat: " & env.getOrDefault(key, "").strip() & ")")

proc dbConfigFromEnv*(env: Table[string, string]): DbConfig =
  ## Membangun konfigurasi dari tabel env (bisa diisi dari proses atau dari test).
  result.target = parseDatabaseUrl(env.getOrDefault("KRAN_DATABASE_URL", ""))
  result.poolSize = parsePositiveInt(env, "KRAN_DB_POOL_SIZE", defaultPoolSize)
  result.acquireTimeoutMs =
    parsePositiveInt(env, "KRAN_DB_ACQUIRE_TIMEOUT_MS", defaultAcquireTimeoutMs)
  result.connectTimeoutMs =
    parsePositiveInt(env, "KRAN_DB_CONNECT_TIMEOUT_MS", defaultConnectTimeoutMs)
  result.statementTimeoutMs =
    parsePositiveInt(env, "KRAN_DB_STATEMENT_TIMEOUT_MS", defaultStatementTimeoutMs)
  let deadlineRaw = env.getOrDefault("KRAN_DB_QUERY_DEADLINE_MS", "").strip()
  if deadlineRaw.len == 0:
    result.queryDeadlineMs = result.statementTimeoutMs + defaultQueryDeadlineMarginMs
  else:
    result.queryDeadlineMs =
      parsePositiveInt(env, "KRAN_DB_QUERY_DEADLINE_MS", result.queryDeadlineMs)
    if result.queryDeadlineMs <= result.statementTimeoutMs:
      fail("KRAN_DB_QUERY_DEADLINE_MS (" & $result.queryDeadlineMs &
        ") harus > KRAN_DB_STATEMENT_TIMEOUT_MS (" & $result.statementTimeoutMs &
        ") supaya kueri yang sah tidak dibunuh lebih dulu")
  result.validateOnAcquire = parseBool(env, "KRAN_DB_VALIDATE_ON_ACQUIRE", true)
  let appName = env.getOrDefault("KRAN_APP_NAME", "").strip()
  result.target.options = "-c statement_timeout=" & $result.statementTimeoutMs &
    " -c application_name=" & (if appName.len > 0: appName else: "kran")

const knownEnvKeys* = [
  "KRAN_DATABASE_URL",
  "KRAN_DB_POOL_SIZE",
  "KRAN_DB_ACQUIRE_TIMEOUT_MS",
  "KRAN_DB_CONNECT_TIMEOUT_MS",
  "KRAN_DB_STATEMENT_TIMEOUT_MS",
  "KRAN_DB_QUERY_DEADLINE_MS",
  "KRAN_DB_VALIDATE_ON_ACQUIRE",
]

proc envTableFromProcess*(): Table[string, string] =
  for k in knownEnvKeys:
    result[k] = getEnv(k)

proc dbConfigFromProcessEnv*(): DbConfig =
  dbConfigFromEnv(envTableFromProcess())

proc databaseUrlSet*(env: Table[string, string]): bool =
  ## `true` bila test integrasi punya alasan untuk berjalan (pola sama `cbs-core`).
  env.getOrDefault("KRAN_DATABASE_URL", "").strip().len > 0
