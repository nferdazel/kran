import std/[unittest, tables, strutils]

import "platform-lib/db/config"

proc env(pairs: openArray[(string, string)]): Table[string, string] =
  for (k, v) in pairs:
    result[k] = v

suite "config: parse URL koneksi":
  test "URL dasar (dev, tunnel)":
    let t = parseDatabaseUrl("postgres://kran_dev:rahasia@127.0.0.1:55432/kran_dev")
    check t.host == "127.0.0.1"
    check t.port == "55432"
    check t.database == "kran_dev"
    check t.user == "kran_dev"
    check t.password == "rahasia"

  test "skema postgresql:// juga diterima, tanpa kredensial":
    let t = parseDatabaseUrl("postgresql://localhost/kran_test")
    check t.host == "localhost"
    check t.port == ""
    check t.database == "kran_test"
    check t.user == ""
    check t.password == ""

  test "password percent-encoded di-decode":
    let t = parseDatabaseUrl("postgres://u:p%40ss%2Fword@host:5432/db")
    check t.user == "u"
    check t.password == "p@ss/word"

  test "password berisi @ dan : tetap terbaca (separator terakhir)":
    let t = parseDatabaseUrl("postgres://u:a@b:c@host:5432/db")
    check t.host == "host"
    check t.user == "u"
    check t.password == "a@b:c"

  test "IPv6 dalam tanda kurung siku":
    let t = parseDatabaseUrl("postgres://u:p@[::1]:5432/db")
    check t.host == "[::1]"
    check t.port == "5432"

  test "URL tidak valid ditolak dengan pesan jelas":
    for bad in ["", "mysql://u@h/db", "postgres://host", "postgres://host/",
                "postgres://u@h:5432/db?sslmode=require", "postgres://h:5432/a/b"]:
      var raised = false
      try:
        discard parseDatabaseUrl(bad)
      except ConfigError as e:
        raised = true
        check e.msg.len > 0
      check raised

suite "config: env":
  test "nilai default":
    let c = dbConfigFromEnv(env({"KRAN_DATABASE_URL": "postgres://u:p@h:5432/db"}))
    check c.poolSize == defaultPoolSize
    check c.acquireTimeoutMs == defaultAcquireTimeoutMs
    check c.connectTimeoutMs == defaultConnectTimeoutMs
    check c.statementTimeoutMs == defaultStatementTimeoutMs
    check c.validateOnAcquire
    check c.target.options.contains("statement_timeout=15000")
    check c.target.options.contains("application_name=kran")

  test "override via env":
    let c = dbConfigFromEnv(env({
      "KRAN_DATABASE_URL": "postgres://u:p@h:5432/db",
      "KRAN_DB_POOL_SIZE": "3",
      "KRAN_DB_ACQUIRE_TIMEOUT_MS": "250",
      "KRAN_DB_CONNECT_TIMEOUT_MS": "2000",
      "KRAN_DB_STATEMENT_TIMEOUT_MS": "1000",
      "KRAN_DB_VALIDATE_ON_ACQUIRE": "0",
      "KRAN_APP_NAME": "kran-api",
    }))
    check c.poolSize == 3
    check c.acquireTimeoutMs == 250
    check c.connectTimeoutMs == 2000
    check c.statementTimeoutMs == 1000
    check not c.validateOnAcquire
    check c.target.options.contains("statement_timeout=1000")
    check c.target.options.contains("application_name=kran-api")

  test "angka/bool tidak valid ditolak (gagal-cepat, bukan diam-diam default)":
    for bad in [("KRAN_DB_POOL_SIZE", "banyak"), ("KRAN_DB_POOL_SIZE", "0"),
                ("KRAN_DB_ACQUIRE_TIMEOUT_MS", "-5"),
                ("KRAN_DB_CONNECT_TIMEOUT_MS", "0"),
                ("KRAN_DB_VALIDATE_ON_ACQUIRE", "mungkin")]:
      var raised = false
      var t = env({"KRAN_DATABASE_URL": "postgres://u:p@h:5432/db"})
      t[bad[0]] = bad[1]
      try:
        discard dbConfigFromEnv(t)
      except ConfigError:
        raised = true
      check raised

  test "poolSize eksplisit di-clamp oleh env bernilai besar":
    let c = dbConfigFromEnv(env({"KRAN_DATABASE_URL": "postgres://u:p@h:5432/db",
                                 "KRAN_DB_POOL_SIZE": "64"}))
    check c.poolSize == 64

  test "databaseUrlSet: penanda test integrasi boleh jalan":
    check databaseUrlSet(env({"KRAN_DATABASE_URL": "postgres://u:p@h:5432/db"}))
    check not databaseUrlSet(env(newSeq[(string, string)]()))
    check not databaseUrlSet(env({"KRAN_DATABASE_URL": "   "}))
