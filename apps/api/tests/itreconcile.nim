## Test integrasi rekonsiliasi saldo simpanan (T-101) — butuh `KRAN_DATABASE_URL`.
##
## Yang dibuktikan: cache `deposit.account_balance` dibandingkan dengan **mutasi tunai**
## (`deposit.transaction`) **dan** **pemindahbukuan** (`deposit.transfer`), bukan dengan jurnal per
## rekening (jurnal PB net-nol di akun 201). Fixture dibuat langsung di DB dengan jurnal seimbang
## supaya test tidak bergantung pada alur HTTP modul lain.

import std/[json, os, strutils, times, unittest]

import db_connector/db_postgres

import dbtools/lib
import kernel/[clock, ids]
import "platform-lib/db/config"
import "platform-lib/db/pool"

import deposit/infrastructure/reconcile_repo
import party/domain/party
import party/infrastructure/party_repo
import product/domain/product
import product/infrastructure/product_repo

import ../src/main

const
  BranchA = "11111111-1111-7111-8111-111111111111"
  BranchB = "22222222-2222-7222-8222-222222222222"
  Actor = "77777777-7777-7777-8777-777777777777"
  Approver = "88888888-8888-7888-8888-888888888888"
  AccA = "aaaaaaaa-aaaa-7aaa-8aaa-aaaaaaaaaaa1"
  AccB = "aaaaaaaa-aaaa-7aaa-8aaa-aaaaaaaaaaa2"
  AccC = "aaaaaaaa-aaaa-7aaa-8aaa-aaaaaaaaaaa3"
  ProductCode = "SAV-REC"

let envT = envTableFromProcess()
if not databaseUrlSet(envT):
  echo "itreconcile: KRAN_DATABASE_URL kosong — dilewati"
  quit(0)

let dbPool = newDbPool(dbConfigFromEnv(envT))
let db = dbPool.acquire()

var PartyId = ""

proc exec(query: SqlQuery, args: varargs[string, `$`]) =
  discard db.execAffectedRows(query, args)

proc textOf(query: SqlQuery, args: varargs[string, `$`]): string =
  db.getValue(query, args)

proc seedJournal(journalId, sourceEvent, amount: string): void =
  ## Jurnal seimbang minimal untuk memenuhi FK `deposit.*.journal_id` dan trigger header.
  ## Header + baris **satu transaksi**: trigger `journal_header_complete` deferred memeriksa saat
  ## COMMIT, jadi header tanpa baris pada autocommit akan ditolak.
  doAssert dbPool.withTx(proc(d: DbConn): int {.closure.} =
    discard d.execAffectedRows(sql"""
      INSERT INTO ledger.journal
        (journal_id, business_date, value_date, source_event, source_ref, idempotency_key,
         created_by)
      VALUES (?::uuid, current_date, current_date, ?, ?::uuid, ?, ?::uuid)""",
      journalId, sourceEvent, Actor, "itreconcile-" & journalId, Actor)
    discard d.execAffectedRows(sql"""
      INSERT INTO ledger.journal_line (journal_id, line_no, gl_account, branch_id, debit, credit)
      VALUES (?::uuid, 1, '201', ?::uuid, ?::numeric, 0),
             (?::uuid, 2, '201', ?::uuid, 0, ?::numeric)""",
      journalId, BranchA, amount, journalId, BranchA, amount)
    1) == 1, "jurnal fixture gagal"

proc insertAccount(accountId, accountNo, branchId, productId, versionId: string): void =
  exec(sql"""
    INSERT INTO deposit.account
      (account_id, account_no, party_id, product_id, product_version_id, branch_id,
       account_type, status, opened_on, created_by, updated_by)
    VALUES (?::uuid, ?, ?::uuid, ?::uuid, ?::uuid, ?::uuid, 'SAVINGS', 'ACTIVE', current_date,
            ?::uuid, ?::uuid)""",
    accountId, accountNo, PartyId, productId, versionId, branchId, Actor, Actor)

proc setBalance(accountId, balance: string): void =
  exec(sql"""
    INSERT INTO deposit.account_balance (account_id, balance) VALUES (?::uuid, ?::numeric)
    ON CONFLICT (account_id) DO UPDATE SET balance = EXCLUDED.balance, updated_at = now()""",
    accountId, balance)

block:
  resetTestSchemas(db, ".")
  discard applyAllMigrations(db, ".")
  execScript(db, readFile("packs/base/generated/param_definitions.sql"))
  execScript(db, readFile("packs/base/generated/param_values.sql"))

  exec(sql"""
    INSERT INTO platform.branch (branch_id, code, name) VALUES
      (?::uuid, '111', 'Cabang Uji'), (?::uuid, '222', 'Cabang Uji Lain')""", BranchA, BranchB)

  # Satu periode OPEN yang menutup hari ini: jurnal fixture butuh periode tanggal bisnis.
  exec(sql"""
    INSERT INTO ledger.period (period_id, starts_on, ends_on, status, created_by, updated_by)
    VALUES (md5('itreconcile|period')::uuid, date_trunc('year', current_date)::date,
            (date_trunc('year', current_date) + interval '1 year' - interval '1 day')::date,
            'OPEN', ?::uuid, ?::uuid)""", Actor, Actor)

  let fixtureClock = fakeClock(dateTime(2026, mOct, 22, 9, 0, 0))
  let party = newParty(newId(fixtureClock), pkPerson, "Rekonsiliasi Uji", Id(BranchA),
    "{seq:6}{check}", nextCifSeq(db))
  doAssert insertParty(db, party, Id(Actor)).len > 0, "party fixture gagal"
  PartyId = $party.partyId

  let prod = Product(productId: newId(fixtureClock), code: ProductCode,
    name: "Simpanan Rekonsiliasi", productType: ptSavings)
  let ver = ProductVersion(versionId: newId(fixtureClock), productId: prod.productId,
    versionNo: 1, effectiveFrom: "2020-01-01")
  discard dbPool.withTx(proc(d: DbConn): int {.closure.} =
    insertProduct(d, prod, Id(Actor))
    insertVersion(d, ver, Id(Actor))
    insertBinding(d, ver.versionId, ParamBinding(paramKey: "product.savings.min_balance",
      value: %"0.0000"))
    1)
  doAssert approveVersion(db, ver.versionId, Id(Approver)), "versi produk fixture gagal di-approve"

  insertAccount(AccA, "1110000001", BranchA, $prod.productId, $ver.versionId)
  insertAccount(AccB, "1110000002", BranchA, $prod.productId, $ver.versionId)
  insertAccount(AccC, "2220000001", BranchB, $prod.productId, $ver.versionId)

  # Mutasi: A setor 100, tarik 30, PB keluar 20 → 50. B menerima PB 20. C belum bermutasi → 0.
  seedJournal("bbbbbbbb-bbbb-7bbb-8bbb-bbbbbbbbbbb1", "RECON_DEPOSIT", "100.0000")
  seedJournal("bbbbbbbb-bbbb-7bbb-8bbb-bbbbbbbbbbb2", "RECON_WITHDRAWAL", "30.0000")
  seedJournal("bbbbbbbb-bbbb-7bbb-8bbb-bbbbbbbbbbb3", "RECON_TRANSFER", "20.0000")
  exec(sql"""
    INSERT INTO deposit.transaction
      (transaction_id, tx_type, account_id, amount, business_date, journal_id, created_by)
    VALUES (md5('itreconcile|cash-deposit')::uuid, 'CASH_DEPOSIT', ?::uuid, '100.0000',
            current_date, 'bbbbbbbb-bbbb-7bbb-8bbb-bbbbbbbbbbb1'::uuid, ?::uuid),
           (md5('itreconcile|cash-withdrawal')::uuid, 'CASH_WITHDRAWAL', ?::uuid, '30.0000',
            current_date, 'bbbbbbbb-bbbb-7bbb-8bbb-bbbbbbbbbbb2'::uuid, ?::uuid)""",
    AccA, Actor, AccA, Actor)
  exec(sql"""
    INSERT INTO deposit.transfer
      (transfer_id, source_account_id, destination_account_id, amount, business_date,
       journal_id, created_by)
    VALUES (md5('itreconcile|transfer')::uuid, ?::uuid, ?::uuid, '20.0000', current_date,
            'bbbbbbbb-bbbb-7bbb-8bbb-bbbbbbbbbbb3'::uuid, ?::uuid)""",
    AccA, AccB, Actor)

  setBalance(AccA, "50.0000")
  setBalance(AccB, "20.0000")
  setBalance(AccC, "0.0000")

suite "rekonsiliasi saldo simpanan (T-101)":
  test "cache bersih + hitungan rekening; PB dihitung di kedua sisi":
    check reconciledAccountCount(db, "") == 3
    check accountBalanceMismatches(db, "").len == 0
    # Kalau PB tidak dihitung, A akan terbaca 70 dan B 0 — dua selisih. Nol selisih membuktikan
    # kedua kaki `deposit.transfer` ikut diperhitungkan.
    check reconciledAccountCount(db, BranchA) == 2
    check accountBalanceMismatches(db, BranchA).len == 0

  test "selisih dilaporkan dengan arah dan nilai yang benar":
    setBalance(AccB, "25.0000")
    let found = accountBalanceMismatches(db, "")
    check found.len == 1
    check found[0].accountNo == "1110000002"
    check found[0].branchId == BranchA
    check found[0].cached == "25.0000"
    check found[0].expected == "20.0000"
    check found[0].delta == "5.0000"
    check runReconcileDeposits(db, "") == 1
    setBalance(AccB, "20.0000")
    check runReconcileDeposits(db, "") == 0

  test "filter cabang menyaring; cache yang hilang ikut dilaporkan":
    check CtlUsage.contains(reconcileDepositsCmd)
    check runReconcileDeposits(db, "bukan-uuid") == 2

    exec(sql"UPDATE deposit.account_balance SET balance = '7.5000' WHERE account_id = ?::uuid",
      AccC)
    check accountBalanceMismatches(db, BranchA).len == 0
    let scoped = accountBalanceMismatches(db, BranchB)
    check scoped.len == 1
    check scoped[0].accountNo == "2220000001"

    exec(sql"DELETE FROM deposit.account_balance WHERE account_id = ?::uuid", AccC)
    let missing = accountBalanceMismatches(db, BranchB)
    check missing.len == 1
    check missing[0].cached.len == 0
    check missing[0].expected == "0.0000"
    check textOf(sql"""
      SELECT count(*)::text FROM deposit.account_balance WHERE account_id = ?::uuid""",
      AccC) == "0"

    # Kontrak CLI: argumen salah = 2, ada selisih = 1 (kode keluar bisa diandalkan gate ops).
    check runCtl(reconcileDepositsCmd, ".", branchId = "bukan-uuid") == 2
    check runCtl(reconcileDepositsCmd, ".", branchId = BranchB) == 1
    check runCtl(reconcileDepositsCmd, ".", branchId = BranchA) == 0

dbPool.release(db)
