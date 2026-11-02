## bench-eod — seed rekening sintetis lalu ukur satu penutupan buku penuh (T-140, spec §23).
##
## **Kenapa alat terpisah.** Target performa spec (§23 Fase 3) adalah EOD 100k rekening simpanan +
## 50k pinjaman < 30 menit di perangkat kelas bawah. Modul pinjaman baru ada di Fase 4, jadi yang
## bisa diukur sekarang adalah sisi simpanan: akrual bunga, deteksi dormant, snapshot buku besar,
## dan gate penutupnya. Alat ini **tidak** mengukur HTTP/UI.
##
## **Yang dibuat (semua sintetis).** Satu cabang, satu produk berjangka ber-versi ACTIVE dengan
## binding akrual, N rekening `TIME_DEPOSIT` bersaldo, satu jurnal agregat untuk seluruh pokok plus
## satu baris subledger per rekening, tanggal buku dan periode GL yang OPEN. Seed memakai SQL massal
## (`generate_series`): 100k panggilan per-rekening akan mengukur biaya seed, bukan biaya EOD.
##
## **Cakupan yang diukur.** Rekening seed tidak diberi `maturity_date`/`aro_instruction`, jadi task
## `deposit.maturity_aro` hanya memindai halaman tanpa memindahkan uang; tanggal buku bawaan juga
## bukan hari kerja terakhir bulan, jadi `ledger.period_close` tidak berjalan. Task dormant juga
## hanya **memindai**: rekening seed beraktivitas pada tanggal buku (cutoff 12 bulan ke belakang),
## sehingga tidak ada transisi status. Angka yang keluar = jalur **akrual + pemindaian dormant +
## snapshot + gate**. Jalur tulis jatuh tempo, transisi dormant, dan tutup periode diukur di
## simulasi 12 bulan (`apps/api/tests/itdaycloser_sim.nim`), bukan di sini.
##
## **Keamanan.** Alat ini **menghapus seluruh schema** sebelum menyemai. Ia menolak berjalan bila
## nama database tidak mengandung `_bench` atau `_test`, kecuali `--force` diberikan — salah ketik
## di sini berarti menghapus data dev.
##
## Keluar: 0 run COMPLETED, 1 run tidak selesai, 2 salah pakai/konfigurasi.

import std/[json, os, strutils, times]

import db_connector/db_postgres

import "platform-lib/db/config"
import "platform-lib/db/pool"

import dbtools/lib

import kernel/[clock, ids, money, result]

import product/domain/product
import product/infrastructure/product_repo

import ../../apps/api/src/daycloser_service
import ../../apps/api/src/deposit_posting

const
  Usage = """pemakaian: bench-eod --accounts <n> [--loans <n>] [--date YYYY-MM-DD] [--force] [--keep]

  --accounts N   jumlah rekening berjangka sintetis (default 1000)
  --loans N      jumlah pinjaman sintetis (default 0)
  --date D       tanggal buku yang ditutup (default 2026-10-28, hari kerja)
  --keep         jangan reset schema (pakai data yang sudah ada)
  --force        izinkan berjalan pada database yang namanya tidak mengandung _bench/_test
"""

  BenchBranchId = "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb"
  BenchPartyId = "cccccccc-cccc-4ccc-8ccc-cccccccccccc"
  BenchProductCode = "BENCH-TD"
  ## Nilai uji, bukan parameter bisnis: alat ini tidak dipakai di produksi.
  BenchRate = "2.5"
  BenchBalance = "10000000.00"
  BenchOpenedOn = "2026-01-01"
  ## Pembuat dan penyetuju harus berbeda: `product_version_self_approval_chk` (maker-checker).
  BenchMaker = "00000000-0000-4000-8000-0000000000e1"
  BenchChecker = "00000000-0000-4000-8000-0000000000e2"

type
  Options = object
    accounts: int
    loans: int
    date: string
    force: bool
    keep: bool

proc parseOptions(args: seq[string]): Options =
  result = Options(accounts: 1000, date: "2026-10-28")
  var i = 0
  while i < args.len:
    case args[i]
    of "--accounts":
      inc i
      if i >= args.len: raise newException(ValueError, "--accounts butuh angka")
      result.accounts = parseInt(args[i])
    of "--loans":
      inc i
      if i >= args.len: raise newException(ValueError, "--loans butuh angka")
      result.loans = parseInt(args[i])
    of "--date":
      inc i
      if i >= args.len: raise newException(ValueError, "--date butuh tanggal")
      result.date = args[i]
    of "--force": result.force = true
    of "--keep": result.keep = true
    of "--help", "-h":
      echo Usage
      quit(0)
    else:
      raise newException(ValueError, "argumen tidak dikenal: " & args[i])
    inc i
  if result.accounts < 1:
    raise newException(ValueError, "--accounts harus >= 1")
  if result.loans < 0:
    raise newException(ValueError, "--loans tidak boleh negatif")

proc guardDatabase(db: DbConn; force: bool) =
  ## Nama database dibaca dari server, bukan dari URL: URL bisa memuat parameter yang membuat
  ## tebakan nama salah, dan salah tebak di sini berarti menghapus schema yang salah.
  let name = db.getValue(sql"SELECT current_database()")
  if force or "_bench" in name or "_test" in name:
    return
  raise newException(ValueError, "database '" & name &
    "' tidak terlihat seperti database uji; pakai --force bila memang disengaja")

proc seed(db: DbConn; opts: Options): string =
  ## Mengembalikan `journal_id` agregat (untuk bukti), setelah seluruh data uji tertulis.
  execScript(db, """
    INSERT INTO platform.branch (branch_id, code, name)
    VALUES ('""" & BenchBranchId & """', '900', 'Cabang Benchmark')
    ON CONFLICT DO NOTHING
  """)
  execScript(db, """
    INSERT INTO party.party (party_id, cif, kind, display_name, branch_id, created_by, updated_by)
    VALUES ('""" & BenchPartyId & """', 'BENCH-0001', 'ORG', 'Anggota Benchmark',
            '""" & BenchBranchId & """', '""" & BenchMaker & """', '""" & BenchMaker & """')
    ON CONFLICT DO NOTHING
  """)
  execScript(db, """
    INSERT INTO ledger.period (period_id, starts_on, ends_on, status, created_by, updated_by)
    VALUES (md5('bench-period-2026')::uuid, DATE '2026-01-01', DATE '2026-12-31', 'OPEN',
            '""" & BenchMaker & """', '""" & BenchMaker & """')
    ON CONFLICT DO NOTHING
  """)
  execScript(db, """
    INSERT INTO platform.business_date (scope_type, scope_id, current_business_date, state,
                                        updated_by)
    VALUES ('INSTITUTION', NULL, DATE '""" & opts.date & """', 'OPEN', '""" & BenchMaker & """')
    ON CONFLICT DO NOTHING
  """)

  let clock = systemClock()
  let productId = newId(clock)
  let versionId = newId(clock)
  insertProduct(db, Product(productId: productId, code: BenchProductCode,
    name: "Deposito Benchmark", productType: ptSavings), Id(BenchMaker))
  insertVersion(db, ProductVersion(versionId: versionId, productId: productId, versionNo: 1,
    effectiveFrom: "2020-01-01"), Id(BenchMaker))
  for binding in @[
      ParamBinding(paramKey: "product.savings.min_balance", value: %"0.00"),
      ParamBinding(paramKey: "product.savings.interest_rate", value: %BenchRate),
      ParamBinding(paramKey: "product.savings.day_count_basis", value: %"ACT_365"),
      ParamBinding(paramKey: "product.savings.rounding_scale", value: %2)]:
    insertBinding(db, versionId, binding)
  doAssert approveVersion(db, versionId, Id(BenchChecker)), "versi produk benchmark gagal di-approve"

  execScript(db, """
    INSERT INTO deposit.account
      (account_id, account_no, party_id, product_id, product_version_id, branch_id,
       account_type, status, opened_on, created_by, updated_by)
    SELECT gen_random_uuid(), '9' || lpad(g::text, 9, '0'),
           '""" & BenchPartyId & """', '""" & $productId & """', '""" & $versionId &
      """',
           '""" & BenchBranchId & """', 'TIME_DEPOSIT', 'ACTIVE',
           DATE '""" & BenchOpenedOn & """',
           '""" & BenchMaker & """', '""" & BenchMaker & """'
      FROM generate_series(1, """ & $opts.accounts & """) g
  """)
  execScript(db, """
    INSERT INTO deposit.account_balance (account_id, balance)
    SELECT a.account_id, """ & BenchBalance &
      """::numeric
      FROM deposit.account a
     WHERE a.branch_id = '""" & BenchBranchId & """'
  """)

  # Satu jurnal agregat (D 101.2 / K 202) untuk seluruh pokok, lalu satu baris subledger per
  # rekening yang menunjuk jurnal itu: `0068` mengizinkan satu jurnal mencatat banyak rekening
  # (UNIQUE `(journal_id, account_id)`), jadi seed tetap murah dan rekonsiliasi tetap cocok.
  let total = moneyFromString($(int64(opts.accounts) * 10_000_000'i64) & ".00")
  if total.isErr:
    raise newException(ValueError, "nominal total benchmark tidak sah")
  let journalId = postJournalSync(db, clock, "DepositPosted", total.value(),
    Id(BenchBranchId), Id(BenchPartyId), BenchOpenedOn, "bench-eod:pokok", Id(BenchMaker),
    BenchProductCode, "TIME_DEPOSIT", "")
  execScript(db, """
    INSERT INTO deposit.transaction
      (transaction_id, tx_type, account_id, amount, business_date, narration, journal_id,
       created_by)
    SELECT gen_random_uuid(), 'CASH_DEPOSIT', a.account_id, """ & BenchBalance &
      """::numeric,
           DATE '""" & BenchOpenedOn & """', 'pokok benchmark', '""" & $journalId &
      """',
           '""" & BenchMaker & """'
      FROM deposit.account a
     WHERE a.branch_id = '""" & BenchBranchId & """'
  """)

  # Pinjaman sintetis (T-172). Yang diukur adalah biaya task `lending.dpd_regrade` +
  # `lending.ppap_provision`, jadi seed cukup menyiapkan populasi: akad `ACTIVE`, baris saldo, dan
  # jadwal 12 angsuran yang sudah lewat jatuh tempo (golongan akhir `LOSS`, penyisihan 100%).
  #
  # **Tanpa jurnal pencairan**: alat ini mengukur biaya, bukan membuktikan identitas akuntansi
  # (itu tugas `itdaycloser_sim` dan `itapi_lending_reports`). Jurnal `LoanDisbursed` akan
  # mengkredit `201` tanpa baris subledger simpanan dan membuat gerbang
  # `ledger.subledger_vs_gl` gagal — kegagalan yang bukan temuan performa.
  if opts.loans > 0:
    execScript(db, """
      INSERT INTO lending.loan_product (product_id, code, name, created_by)
      VALUES (md5('bench-loan-product')::uuid, 'BENCH-LN', 'Pinjaman Benchmark',
              '""" & BenchMaker & """')
      ON CONFLICT DO NOTHING
    """)
    execScript(db, """
      INSERT INTO lending.loan_product_version
        (version_id, product_id, version_no, status, schedule_method, tenor_months, annual_rate,
         allocation_order, created_by, approved_by)
      VALUES (md5('bench-loan-version')::uuid, md5('bench-loan-product')::uuid, 1, 'ACTIVE', 'FLAT',
              12, 0, 'PRINCIPAL,INTEREST,PENALTY', '""" & BenchMaker &
        """',
              '""" & BenchChecker & """')
      ON CONFLICT DO NOTHING
    """)
    execScript(db, """
      INSERT INTO lending.loan
        (loan_id, party_id, product_version_id, branch_id, principal, status, disbursed_on,
         maturity_on, applied_by, approved_by)
      SELECT gen_random_uuid(), '""" & BenchPartyId &
        """', md5('bench-loan-version')::uuid,
             '""" & BenchBranchId &
        """', '12000000.00', 'ACTIVE', DATE '2026-01-01',
             DATE '2026-12-31', '""" & BenchMaker & """', '""" & BenchChecker &
        """'
        FROM generate_series(1, """ & $opts.loans & """) g
    """)
    execScript(db, """
      INSERT INTO lending.loan_balance
        (loan_id, principal_outstanding, interest_overdue, penalty_outstanding)
      SELECT loan_id, principal, 0, 0 FROM lending.loan
       WHERE branch_id = '""" & BenchBranchId & """'
    """)
    execScript(db, """
      INSERT INTO lending.installment
        (loan_id, no, due_on, principal_due, interest_due, penalty_due)
      SELECT l.loan_id, g, (DATE '2026-01-01' + ((g - 1) || ' month')::interval)::date,
             '1000000.00', 0, 0
        FROM lending.loan l, generate_series(1, 12) AS g
       WHERE l.branch_id = '""" & BenchBranchId & """'
    """)
  $journalId

proc main(args: seq[string]): int =
  let opts = parseOptions(args)
  let env = envTableFromProcess()
  if not databaseUrlSet(env):
    stderr.writeLine "bench-eod: KRAN_DATABASE_URL kosong"
    return 2
  let pool = newDbPool(dbConfigFromEnv(env))
  defer: pool.close()
  let db = pool.acquire()
  defer: pool.release(db)

  guardDatabase(db, opts.force)
  # NOTICE dari `DROP SCHEMA ... CASCADE` dan trigger migrasi mengubur keluaran JSON yang dibaca
  # operator; yang penting hanya WARNING ke atas.
  execScript(db, "SET client_min_messages = warning")
  if not opts.keep:
    resetTestSchemas(db, ".")
    discard applyAllMigrations(db, ".")
    execScript(db, readFile("packs/base/generated/param_definitions.sql"))
    execScript(db, readFile("packs/base/generated/param_values.sql"))

  let startedSeed = epochTime()
  # Satu transaksi untuk jurnal agregat + baris subledger: trigger `ledger` menuntut jurnal punya
  # minimal dua baris saat commit, jadi header tidak boleh hidup sendiri di autocommit.
  let journalId = pool.withTx(proc(tx: DbConn): string {.closure.} = seed(tx, opts))
  let seedSeconds = epochTime() - startedSeed

  let clock = systemClock()
  let started = epochTime()
  let res = startRunAction(pool, clock, opts.date, bootstrap = false)
  let seconds = epochTime() - started

  var tasks: JsonNode = newJArray()
  var state = "UNKNOWN"
  if res.hasSnapshot:
    state = $res.snapshot.state
    for t in res.snapshot.tasks:
      tasks.add %*{"id": t.taskId, "state": $t.state, "error": t.errorCode}
  let units = opts.accounts + opts.loans
  let summary: JsonNode = %*{
    "accounts": opts.accounts,
    "loans": opts.loans,
    "businessDate": opts.date,
    "seedSeconds": seedSeconds,
    "eodSeconds": seconds,
    "millisPerAccount": (if opts.accounts > 0: seconds * 1000.0 / float(opts.accounts) else: 0.0),
    "millisPerUnit": (if units > 0: seconds * 1000.0 / float(units) else: 0.0),
    "state": state,
    "message": res.message,
    "aggregateJournal": journalId,
    "tasks": tasks,
  }
  echo summary.pretty
  if state == "COMPLETED": 0 else: 1

when isMainModule:
  try:
    quit(main(commandLineParams()))
  except ValueError as e:
    stderr.writeLine "bench-eod: " & e.msg
    quit(2)
