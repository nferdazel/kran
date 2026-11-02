## Simulasi 12 bulan sintetis untuk Fase 3 (T-140, spec §23 "Simulasi 12 bulan sintetis lulus").
##
## Yang dibuktikan: penutupan **setiap hari kerja** selama satu tahun buku berjalan sampai selesai —
## akrual bunga harian, jatuh tempo/ARO, deteksi dormant, snapshot & gate buku besar, penutupan
## periode bulanan — dan invariannya tetap utuh di akhir:
##
##   1. setiap penutupan `COMPLETED` (tidak ada gate yang gagal di tengah jalan);
##   2. saldo cache rekening = subledger (`reconcile-deposits`);
##   3. tidak ada akrual ganda per rekening+tanggal, tidak ada akrual bukan nol tanpa jurnal, dan
##      total akrual = total debit beban bunga di GL;
##   4. deposito `NONE` tertutup dengan bunga yang dibayar = akrual terakhirnya;
##   5. ARO `PRINCIPAL` memperpanjang tanggal jatuh tempo, `PRINCIPAL_AND_INTEREST` menambah pokok;
##   6. rekening tabungan yang tidak pernah dipakai menjadi `DORMANT`, rekening tujuan tetap aktif;
##   7. jurnal seimbang (total debit = total kredit) — pemeriksaan terakhir, bukan asumsi.
##
## Data **sintetis**: satu cabang, satu anggota, dua rekening tabungan, enam deposito berjangka
## dengan tenor dan instruksi ARO berbeda. Tidak ada data nyata.
##
## **Batas yang disengaja** (dicatat di `docs/milestones/M3-report.md`):
##   - siklus ARO kedua/ketiga ikut berjalan; akrualnya tetap memakai model kumulatif D-154, yang
##     pada `PRINCIPAL_AND_INTEREST` menilai ulang pokok baru untuk hari-hari sebelumnya (O-109).
##     Invarian akuntansi tetap utuh; angka bunganya yang belum benar secara ekonomi.
##   - tidak ada transaksi teller/PB selama tahun berjalan (dibuktikan suite lain); simulasi ini
##     fokus pada mesin penutupan.
##   - satu proses, satu cabang, satu institusi; paralelisme/worker pool tidak diuji di sini.

import std/[json, options, os, strutils, times, unittest]

import db_connector/db_postgres

import "platform-lib/db/config"
import "platform-lib/db/pool"
import dbtools/lib

import kernel/[clock, dayclose, ids, money, result]

import daycloser/domain/types
import platform/domain/[calendar, scope]
import platform/infrastructure/calendar_repo

import deposit/domain/[account, transaction]
import deposit/infrastructure/[account_repo, reconcile_repo, transaction_repo]
import lending/infrastructure/[loan_repo, report_repo, restructure_repo]
import party/domain/party
import product/domain/product
import product/infrastructure/product_repo

import ../src/daycloser_service
import ../src/deposit_posting
import ../src/posting

const
  repoRoot = "."
  BranchId = "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa"
  FirstDate = "2026-01-01"
  LastDate = "2026-12-31"
  Rate = "2.5"
  Basis = "ACT_365"
  Actor = "00000000-0000-4000-8000-0000000000f1"
  Checker = "00000000-0000-4000-8000-0000000000f2"

let envT = envTableFromProcess()
if not databaseUrlSet(envT):
  echo "itdaycloser_sim: KRAN_DATABASE_URL kosong — dilewati"
  quit(0)

let dbPool = newDbPool(dbConfigFromEnv(envT))
let db = dbPool.acquire()

resetTestSchemas(db, repoRoot)
discard applyAllMigrations(db, repoRoot)
execScript(db, readFile(repoRoot / "packs/base/generated/param_definitions.sql"))
execScript(db, readFile(repoRoot / "packs/base/generated/param_values.sql"))

let simClock = systemClock()

proc bd(): Option[BusinessDateRow] =
  dbPool.withConn(proc(d: DbConn): Option[BusinessDateRow] =
    businessDateOf(d, institutionScope()))

proc stateOf(accountId: Id): tuple[status, maturity: string] =
  let row = db.getAllRows(sql"""
    SELECT status, coalesce(to_char(maturity_date, 'YYYY-MM-DD'), '')
      FROM deposit.account WHERE account_id = ?""", $accountId)
  if row.len == 0:
    return ("", "")
  (row[0][0], row[0][1])

proc balanceOf(accountId: Id): string =
  db.getValue(sql"""
    SELECT coalesce(balance::text, '') FROM deposit.account_balance WHERE account_id = ?""",
    $accountId)

proc lastAccrualCumulative(accountId: Id): string =
  db.getValue(sql"""
    SELECT coalesce(cumulative::text, '0.00') FROM deposit.interest_accrual
     WHERE account_id = ? ORDER BY business_date DESC LIMIT 1""", $accountId)

proc subledgerSum(accountId: Id): string =
  db.getValue(sql"""
    SELECT (coalesce(sum(CASE WHEN tx_type IN ('CASH_DEPOSIT', 'MATURITY_IN',
                                             'INTEREST_CREDIT', 'LOAN_DISBURSEMENT')
                              THEN amount ELSE -amount END), 0))::numeric(24,2)::text
      FROM deposit.transaction WHERE account_id = ?""", $accountId)

proc interestPaidFor(accountId: Id): string =
  ## Kredit `201` pada jurnal `InterestPosted` milik rekening deposito itu: bunga yang benar-benar
  ## dibayarkan ke rekening tujuan.
  db.getValue(sql"""
    SELECT coalesce(sum(l.credit), 0)::numeric(24,2)::text
      FROM ledger.journal j
      JOIN ledger.journal_line l USING (journal_id)
     WHERE j.source_event = 'InterestPosted' AND j.source_ref = ?::uuid
       AND l.gl_account = '201'""", $accountId)

# ---------------------------------------------------------------------------------------------
# Seed sintetis
# ---------------------------------------------------------------------------------------------

let testParty = newId(simClock)
let testProduct = newId(simClock)
let testVersion = newId(simClock)

proc addSavings(openedOn, balance: string): Id =
  var a = newAccount(newId(simClock), testParty, testProduct, testVersion, "SIM-DEP", Id(BranchId),
    "901", openedOn, nextAccountSeq(db))
  discard dbPool.withTx(proc(d: DbConn): int =
    insertAccount(d, a, Id(Actor))
    1)
  if balance != "0.00":
    let value = moneyFromString(balance).value()
    discard dbPool.withTx(proc(d: DbConn): int =
      let journalId = postRuleJournalSync(d, simClock, "DepositPosted", value, Id(BranchId),
        a.accountId, openedOn, "sim.savings:" & $a.accountId, Id(Actor),
        %*{"product": "SIM-DEP", "accountType": "SAVINGS"})
      insertTransaction(d, Transaction(transactionId: newId(simClock), txType: ttCashDeposit,
        accountId: a.accountId, amount: value, businessDate: openedOn,
        narration: "saldo awal simulasi", journalId: journalId), Id(Actor))
      d.exec(sql"UPDATE deposit.account_balance SET balance = ?::numeric WHERE account_id = ?",
        balance, $a.accountId)
      1)
  a.accountId

proc addDeposit(openedOn, principal, maturityDate, aro: string): Id =
  var a = newAccount(newId(simClock), testParty, testProduct, testVersion, "SIM-DEP", Id(BranchId),
    "901", openedOn, nextAccountSeq(db))
  a.accountType = atTimeDeposit
  discard dbPool.withTx(proc(d: DbConn): int =
    insertAccount(d, a, Id(Actor))
    d.exec(sql"""
      UPDATE deposit.account SET maturity_date = ?::date, aro_instruction = ?
       WHERE account_id = ?""", maturityDate, aro, $a.accountId)
    1)
  let value = moneyFromString(principal).value()
  discard dbPool.withTx(proc(d: DbConn): int =
    let journalId = postRuleJournalSync(d, simClock, "DepositPosted", value, Id(BranchId),
      a.accountId, openedOn, "sim.deposit:" & $a.accountId, Id(Actor),
      %*{"product": "SIM-DEP", "accountType": "TIME_DEPOSIT"})
    insertTransaction(d, Transaction(transactionId: newId(simClock), txType: ttCashDeposit,
      accountId: a.accountId, amount: value, businessDate: openedOn,
      narration: "pokok simulasi", journalId: journalId), Id(Actor))
    d.exec(sql"UPDATE deposit.account_balance SET balance = ?::numeric WHERE account_id = ?",
      principal, $a.accountId)
    1)
  a.accountId

let loanProduct = newId(simClock)
let loanVersion = newId(simClock)

block seed:
  execScript(db, """
    INSERT INTO lending.loan_product (product_id, code, name, created_by)
    VALUES ('""" & $loanProduct & """', 'SIM-LN', 'Pinjaman Simulasi', '""" & Actor & """')
  """)
  execScript(db, """
    INSERT INTO lending.loan_product_version
      (version_id, product_id, version_no, status, schedule_method, tenor_months, annual_rate,
       allocation_order, created_by, approved_by)
    VALUES ('""" & $loanVersion & """', '""" & $loanProduct &
      """', 1, 'ACTIVE', 'FLAT', 12, 0, 'PRINCIPAL,INTEREST,PENALTY',
      '""" & Actor & """', '""" & Checker & """')
  """)

block seed:
  execScript(db, """
    INSERT INTO platform.branch (branch_id, code, name)
    VALUES ('""" & BranchId & """', '901', 'Cabang Simulasi')
  """)
  # Satu periode GL per bulan kalender: penutupan EOM menutup periode yang memuat tanggal buku, dan
  # periode bulan berikutnya harus sudah ada (DAY-324). Semua OPEN sejak awal.
  execScript(db, """
    INSERT INTO ledger.period (period_id, starts_on, ends_on, status, created_by, updated_by)
    SELECT md5('sim-period-' || m)::uuid,
           (DATE '2026-01-01' + (m - 1) * INTERVAL '1 month')::date,
           (DATE '2026-01-01' + m * INTERVAL '1 month' - INTERVAL '1 day')::date,
           'OPEN', '""" & Actor & """', '""" & Actor & """'
      FROM generate_series(1, 12) AS m
  """)
  execScript(db, """
    INSERT INTO party.party (party_id, cif, kind, display_name, branch_id, created_by, updated_by)
    VALUES ('""" & $testParty & """', 'SIM-0001', 'PERSON', 'Anggota Simulasi',
            '""" & BranchId & """', '""" & Actor & """', '""" & Actor & """')
  """)
  discard dbPool.withTx(proc(d: DbConn): int =
    insertProduct(d, Product(productId: testProduct, code: "SIM-DEP",
      name: "Simpanan Simulasi", productType: ptSavings), Id(Actor))
    insertVersion(d, ProductVersion(versionId: testVersion, productId: testProduct, versionNo: 1,
      effectiveFrom: "2020-01-01"), Id(Actor))
    # Tenor perpanjangan dari atribut produk (D-165). 365 hari menjaga simulasi tetap satu siklus
    # per rekening di dalam tahun buku, tanpa bergantung pada selisih tanggal buka.
    for binding in @[
        ParamBinding(paramKey: "product.savings.min_balance", value: %"0.00"),
        ParamBinding(paramKey: "product.savings.interest_rate", value: %Rate),
        ParamBinding(paramKey: "product.savings.day_count_basis", value: %Basis),
        ParamBinding(paramKey: "product.savings.rounding_scale", value: %2),
        ParamBinding(paramKey: "product.savings.rollover_tenor_days", value: %365)]:
      insertBinding(d, testVersion, binding)
    1)
  doAssert approveVersion(db, testVersion, Id(Checker)), "versi produk simulasi gagal di-approve"

# Urutan pembuatan menentukan `account_no`: tabungan tujuan lebih dulu, jadi ia yang dipilih
# `activeSavingsAccount` (ORDER BY account_no LIMIT 1).
let SavingsTarget = addSavings("2026-01-01", "1000000.00")

proc addLoan(principal, firstDue: string): Id =
  ## Pencairan sintetis: 12 angsuran pokok rata, bunga 0 (perhitungan bunga pinjaman diuji golden
  ## test T-162, bukan di sini), jurnal `LoanDisbursed`, dan **kredit rekening simpanan** anggota
  ## seperti jalur nyata (D-182). Tanpa kredit itu gerbang `ledger.subledger_vs_gl` gagal: GL `201`
  ## akan lebih besar dari subledger simpanan.
  let loanId = newId(simClock)
  let value = moneyFromString(principal).value()
  discard dbPool.withTx(proc(d: DbConn): int =
    d.exec(sql"""
      INSERT INTO lending.loan (loan_id, party_id, product_version_id, branch_id, principal,
                                status, disbursed_on, maturity_on, applied_by, approved_by)
      VALUES (?, ?, ?, ?, ?::numeric, 'ACTIVE', ?::date,
              (?::date + interval '11 months')::date, ?::uuid, ?::uuid)""",
      $loanId, $testParty, $loanVersion, BranchId, principal, FirstDate, firstDue, Actor, Checker)
    insertBalance(d, loanId, value)
    insertScheduleVersion(d, loanId, 1, FirstDate, "jadwal pencairan", Id(Actor))
    d.exec(sql"""
      INSERT INTO lending.installment
        (loan_id, no, due_on, principal_due, interest_due, penalty_due)
      SELECT ?, no, (?::date + ((no - 1) || ' month')::interval)::date,
             (?::numeric / 12), 0, 0
        FROM generate_series(1, 12) AS no""", $loanId, firstDue, principal)
    let journalId = postRuleJournalSync(d, simClock, "LoanDisbursed", value, Id(BranchId), loanId,
      FirstDate, "sim.loan:" & $loanId, Id(Actor), %*{"loanId": $loanId})
    insertTransaction(d, Transaction(transactionId: newId(simClock), txType: ttLoanDisbursement,
      accountId: SavingsTarget, amount: value, businessDate: FirstDate,
      narration: "pencairan pinjaman simulasi", journalId: journalId), Id(Actor))
    d.exec(sql"""
      UPDATE deposit.account_balance SET balance = balance + ?::numeric WHERE account_id = ?""",
      principal, $SavingsTarget)
    1)
  loanId
let SavingsQuiet = addSavings("2025-12-01", "0.00")

let DepositNone1 = addDeposit("2026-01-01", "10000000.00", "2026-02-16", "NONE")
let DepositNone2 = addDeposit("2026-01-01", "5000000.00", "2026-06-15", "NONE")
let DepositPrincipal = addDeposit("2026-01-01", "8000000.00", "2026-03-16", "PRINCIPAL")
let DepositCapitalized = addDeposit("2026-01-01", "6000000.00", "2026-04-15",
  "PRINCIPAL_AND_INTEREST")
let DepositPrincipal2 = addDeposit("2026-01-01", "4000000.00", "2026-08-17", "PRINCIPAL")
let DepositNone3 = addDeposit("2026-01-01", "3000000.00", "2026-12-15", "NONE")

# Dua pinjaman sintetis (T-172): satu menunggak sepanjang tahun, satu baru jatuh tempo tahun
# berikutnya. Keduanya dicairkan 1 Januari, jadi snapshot kolektibilitas harus ada untuk setiap
# tanggal tutup, bukan hanya pada hari pencairan.
let LoanOverdue = addLoan("12000000.00", "2026-02-01")
let LoanCurrent = addLoan("6000000.00", "2027-01-15")

suite "simulasi 12 bulan: penutupan harian sampai akhir tahun buku":

  test "setiap hari kerja 2026 ditutup COMPLETED":
    # Bootstrap menetapkan tanggal buku pertama sekaligus menutupnya.
    let first = startRunAction(dbPool, simClock, FirstDate, bootstrap = true)
    check first.status == asOk
    check first.hasSnapshot
    check first.snapshot.state == rsCompleted
    var closes = 1
    var date = bd().get.currentDate

    while date <= LastDate and closes <= 300:
      let res = startRunAction(dbPool, simClock, date)
      check res.status == asOk
      check res.hasSnapshot
      if res.snapshot.state != rsCompleted:
        echo "penutupan ", date, " berakhir ", res.snapshot.state, ": ", res.message
        for t in res.snapshot.tasks:
          if t.state != tsSucceeded:
            echo "  task ", t.taskId, " = ", t.state, " ", t.errorCode
      check res.snapshot.state == rsCompleted
      inc closes
      date = bd().get.currentDate

    # Pagar: kalender yang salah (tanggal buku tidak pernah maju) harus gagal cepat.
    check closes <= 300
    check closes >= 250
    let finalBd = bd()
    check finalBd.isSome
    check finalBd.get.state == bdsOpen
    check finalBd.get.currentDate > LastDate
    check db.getValue(sql"""
      SELECT count(*)::text FROM daycloser.run
       WHERE state = 'COMPLETED'
         AND business_date BETWEEN DATE '2026-01-01' AND DATE '2026-12-31'
      """) == $closes

  test "jatuh tempo: NONE menutup dan membayar pokok + bunga akrual":
    for accountId in [DepositNone1, DepositNone2, DepositNone3]:
      check stateOf(accountId).status == "CLOSED"
      check balanceOf(accountId) == "0.00"
      # Setiap sen bunga yang keluar adalah akrual yang sudah dijurnal sebelumnya.
      check interestPaidFor(accountId) == lastAccrualCumulative(accountId)
      check interestPaidFor(accountId) != "0.00"

  test "ARO: PRINCIPAL memperpanjang tenor, PRINCIPAL_AND_INTEREST menambah pokok":
    for accountId in [DepositPrincipal, DepositPrincipal2]:
      let s = stateOf(accountId)
      check s.status == "ACTIVE"
      check s.maturity > LastDate
    check balanceOf(DepositPrincipal) == "8000000.00"
    check balanceOf(DepositPrincipal2) == "4000000.00"

    let capitalized = stateOf(DepositCapitalized)
    check capitalized.status == "ACTIVE"
    check capitalized.maturity > LastDate
    let money = moneyFromString(balanceOf(DepositCapitalized))
    check money.isOk
    check money.value() > moneyFromString("6000000.00").value()

  test "dormant: tabungan yang tidak dipakai ditandai, tabungan tujuan tetap aktif":
    check stateOf(SavingsQuiet).status == "DORMANT"
    check stateOf(SavingsTarget).status == "ACTIVE"

  test "invarian akuntansi bertahan setelah 12 bulan":
    # 1. Cache saldo = subledger per rekening.
    let mismatches = dbPool.withConn(proc(d: DbConn): seq[BalanceMismatch] =
      accountBalanceMismatches(d, BranchId))
    if mismatches.len > 0:
      for m in mismatches:
        echo "selisih ", m.accountNo, ": cache ", m.cached, " vs subledger ", m.expected
    check mismatches.len == 0
    for accountId in [SavingsTarget, SavingsQuiet, DepositPrincipal, DepositCapitalized,
                      DepositPrincipal2]:
      check balanceOf(accountId) == subledgerSum(accountId)

    # 2. Akrual: tanpa baris ganda, tanpa baris bukan nol tanpa jurnal, total = beban GL.
    check db.getValue(sql"""
      SELECT count(*)::text FROM (
        SELECT account_id, business_date FROM deposit.interest_accrual
         GROUP BY account_id, business_date HAVING count(*) > 1) dup""") == "0"
    check db.getValue(sql"""
      SELECT count(*)::text FROM deposit.interest_accrual
       WHERE journal_id IS NULL AND amount <> 0""") == "0"
    let accrualTotal = db.getValue(sql"""
      SELECT coalesce(sum(amount), 0)::text FROM deposit.interest_accrual""")
    let expenseDebit = db.getValue(sql"""
      SELECT coalesce(sum(l.debit), 0)::text
        FROM ledger.journal_line l
        JOIN ledger.journal j USING (journal_id)
       WHERE l.gl_account = '501' AND j.source_event = 'InterestAccrued'""")
    check accrualTotal == expenseDebit

    # 3. Jurnal seimbang — pemeriksaan terakhir, bukan asumsi dari gate yang sudah lulus.
    check db.getValue(sql"""
      SELECT coalesce(sum(debit), 0)::text FROM ledger.journal_line""") ==
      db.getValue(sql"""
      SELECT coalesce(sum(credit), 0)::text FROM ledger.journal_line""")

    # 4. Seluruh periode 2026 ditutup oleh task EOM, bukan dibiarkan OPEN.
    check db.getValue(sql"""
      SELECT count(*)::text FROM ledger.period
       WHERE starts_on >= DATE '2026-01-01' AND ends_on <= DATE '2026-12-31'
         AND status = 'CLOSED'""") == "12"


  test "pinjaman: kolektibilitas, penyisihan, dan rekonsiliasi utuh setelah 12 bulan":
    let days = db.getValue(sql"""
      SELECT count(*)::text FROM daycloser.run
       WHERE state = 'COMPLETED'
         AND business_date BETWEEN DATE '2026-01-01' AND DATE '2026-12-31'""")
    let dayCount = parseInt(days)
    check dayCount >= 250

    # 1. Satu snapshot per pinjaman per tanggal buku — tidak ada hari yang terlewat dan tidak ada
    #    baris ganda (PK `(loan_id, business_date)` yang menjaganya, invarian diuji di sini).
    check db.getValue(sql"""
      SELECT count(*)::text FROM lending.collectibility_snapshot""") == $(dayCount * 2)
    check db.getValue(sql"""
      SELECT count(*)::text FROM lending.ppap_snapshot""") == $(dayCount * 2)

    # 2. Golongan akhir mengikuti DPD: yang menunggak sejak Februari = LOSS (di atas 180 hari),
    #    yang angsurannya baru jatuh tempo tahun berikutnya = COLLECTIBLE.
    check db.getValue(sql"SELECT collectibility FROM lending.loan WHERE loan_id = ?",
      $LoanOverdue) == "LOSS"
    check db.getValue(sql"SELECT collectibility FROM lending.loan WHERE loan_id = ?",
      $LoanCurrent) == "COLLECTIBLE"

    # 3. Identitas rekonsiliasi T-171 pada keadaan akhir: GL 110 = Σ sisa pokok, dan
    #    GL 111 = Σ penyisihan terakhir. Fungsi yang dipakai laporan, bukan salinan query.
    let glReceivable = db.getValue(sql"""
      SELECT (coalesce(sum(debit), 0) - coalesce(sum(credit), 0))::numeric(24,2)::text
        FROM ledger.journal_line WHERE gl_account = '110'""")
    let glAllowance = db.getValue(sql"""
      SELECT (coalesce(sum(credit), 0) - coalesce(sum(debit), 0))::numeric(24,2)::text
        FROM ledger.journal_line WHERE gl_account = '111'""")
    check glReceivable == "18000000.00"
    check glReceivable == loanReceivableSubledger(db)
    check glAllowance == allowanceSubledger(db)
    # LOSS = 100% × 12.000.000,00; COLLECTIBLE = 0,5% × 6.000.000,00 = 30.000,00 (D-196).
    check glAllowance == "12030000.00"

    # 4. Laporan tanggal tutup terakhir memakai snapshot tanggal itu, bukan keadaan hari ini.
    let lastDate = db.getValue(sql"""
      SELECT max(business_date)::text FROM daycloser.run
       WHERE state = 'COMPLETED'
         AND business_date BETWEEN DATE '2026-01-01' AND DATE '2026-12-31'""")
    let arrears = arrearsRows(db, lastDate)
    check arrears.len == 1
    check arrears[0].loanId == LoanOverdue
    check arrears[0].grade == "LOSS"
    check arrears[0].principal != "0.00"
    let allowance = allowanceRows(db, lastDate)
    check allowance.len == 2
    var lossAllowance = ""
    for row in allowance:
      if row.grade == "LOSS":
        lossAllowance = row.allowance
    check lossAllowance == "12000000.00"

block cleanup:
  # Suite lain (dan e2e) memakai DB yang sama: jangan tinggalkan tanggal buku yang menahan
  # penutupan atau data simulasi yang membuat hitungan mereka meleset.
  execScript(db, "DELETE FROM platform.business_date")
