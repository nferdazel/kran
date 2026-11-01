## Integrasi DB modul `lending` (T-161) — butuh `KRAN_DATABASE_URL`.
##
## Yang dibuktikan di sini adalah **invarian skema**, bukan perilaku use case (itu T-163+):
## empat mata pada versi produk & akad, pinjaman berjalan wajib punya tanggal cair, saldo tidak
## negatif, jadwal unik per nomor, dan baris jadwal yang sudah dibayar tidak bisa diubah.
##
## Baris dibuat dengan SQL langsung: modul ini belum punya repository (T-161 hanya model + skema),
## dan menulis repository hanya untuk test akan mengunci bentuk API lebih awal dari kebutuhannya.

import std/[options, times, unittest]

import db_connector/db_postgres

import "platform-lib/db/config"
import "platform-lib/db/pool"
import dbtools/lib
import kernel/[clock, ids]
import party/domain/party
import party/infrastructure/party_repo

let envT = envTableFromProcess()
if not databaseUrlSet(envT):
  echo "itlending: KRAN_DATABASE_URL kosong — dilewati"
  quit(0)

let dbPool = newDbPool(dbConfigFromEnv(envT))
let db = dbPool.acquire()

resetTestSchemas(db, ".")
discard applyAllMigrations(db, ".")

let
  testClock = fakeClock(dateTime(2026, mNov, 1, 9, 0, 0))
  branch = Id("11111111-1111-7111-8111-111111111111")
  actor = Id("77777777-7777-7777-8777-777777777777")
  maker = Id("88888888-8888-7888-8888-888888888888")
  approver = Id("99999999-9999-7999-8999-999999999999")

let partyRow = newParty(newId(testClock), pkPerson, "Siti Aminah", branch, "{seq:6}{check}",
  nextCifSeq(db))
discard insertParty(db, partyRow, actor)

var productSeq = 0

proc sqlText(value: string): string =
  ## Fragmen SQL untuk kolom yang boleh NULL: `'nilai'` atau `NULL`. Dipakai supaya `date`/`uuid`
  ## bisa dikirim kosong tanpa menyambung string SQL di tengah literal multi-baris (nimpretty
  ## memecah/menyambung baris dan `"x" &y` dibaca sebagai operator awalan, bukan infiks).
  ## Semua nilai berasal dari test ini sendiri, bukan masukan pengguna.
  if value.len == 0: "NULL" else: "'" & value & "'"

proc newProductVersion(approvedBy: Option[Id]): Id =
  inc productSeq
  let
    productId = newId(testClock)
    versionId = newId(testClock)
    # `code` pendek dan unik per fixture: kolomnya CHECK 1..32 karakter.
    code = "LN" & $productSeq
  db.exec(sql"""
    INSERT INTO lending.loan_product (product_id, code, name, created_by)
    VALUES (?, ?, 'Pinjaman Modal Kerja', ?)
  """, $productId, code, $actor)
  # `approved_by` NULL vs uuid harus literal: kolomnya `uuid`, dan string kosong bukan NULL.
  var q = """
    INSERT INTO lending.loan_product_version
      (version_id, product_id, version_no, status, schedule_method, tenor_months, annual_rate,
       allocation_order, created_by, approved_by)
    VALUES (?, ?, 1, """
  q.add(sqlText(if approvedBy.isSome: "ACTIVE" else: "DRAFT"))
  q.add(", 'ANNUITY', 12, 150000, 'INTEREST,PRINCIPAL,PENALTY', ?, ")
  q.add(sqlText(if approvedBy.isSome: $approvedBy.get() else: ""))
  q.add(")")
  db.exec(sql(q), $versionId, $productId, $maker)
  versionId

proc expectDbError(body: proc()) =
  var raised = false
  try:
    body()
  except DbError:
    raised = true
  check raised

proc loanId(): Id = newId(testClock)

proc insertLoan(loan: Id; versionId: Id; status: string; disbursed: bool; approved: bool) =
  # `disbursed_on`/`approved_by` NULL vs nilai harus literal (kolom `date`/`uuid`).
  var q = """
    INSERT INTO lending.loan
      (loan_id, party_id, product_version_id, branch_id, principal, status, disbursed_on,
       applied_by, approved_by)
    VALUES (?, ?, ?, ?, 5000000.00, ?, """
  q.add(sqlText(if disbursed: "2026-11-01" else: ""))
  q.add(", ?, ")
  q.add(sqlText(if approved: $approver else: ""))
  q.add(")")
  db.exec(sql(q), $loan, $partyRow.partyId, $versionId, $branch, status, $maker)

suite "lending: produk & versi":
  test "versi DRAFT tersimpan, versi ACTIVE butuh penyetuju berbeda":
    let draft = newProductVersion(none(Id))
    check db.getValue(sql"SELECT status FROM lending.loan_product_version WHERE version_id = ?",
      $draft) == "DRAFT"

    # Penyetuju = pembuat ditolak DB (empat mata), bukan hanya oleh use case.
    expectDbError(proc() =
      db.exec(sql"UPDATE lending.loan_product_version SET status = 'ACTIVE', approved_by = ? WHERE version_id = ?",
        $maker, $draft))

    db.exec(sql"UPDATE lending.loan_product_version SET status = 'ACTIVE', approved_by = ? WHERE version_id = ?",
      $approver, $draft)
    check db.getValue(sql"SELECT status FROM lending.loan_product_version WHERE version_id = ?",
      $draft) == "ACTIVE"

  test "versi ACTIVE tidak bisa diubah atau dihapus":
    let v = newProductVersion(some(approver))
    expectDbError(proc() =
      db.exec(sql"UPDATE lending.loan_product_version SET tenor_months = 24 WHERE version_id = ?", $v))
    expectDbError(proc() =
      db.exec(sql"DELETE FROM lending.loan_product_version WHERE version_id = ?", $v))

  test "metode jadwal di luar tiga yang dijual ditolak DB":
    let v = newProductVersion(none(Id))
    expectDbError(proc() =
      db.exec(sql"UPDATE lending.loan_product_version SET schedule_method = 'BALLOON' WHERE version_id = ?", $v))

suite "lending: akad pinjaman":
  test "pinjaman APPLIED tersimpan tanpa penyetuju":
    let
      v = newProductVersion(some(approver))
      l = loanId()
    insertLoan(l, v, "APPLIED", disbursed = false, approved = false)
    check db.getValue(sql"SELECT status FROM lending.loan WHERE loan_id = ?", $l) == "APPLIED"

  test "status di atas APPLIED butuh penyetuju yang berbeda":
    let
      v = newProductVersion(some(approver))
      l = loanId()
    expectDbError(proc() = insertLoan(l, v, "APPROVED", disbursed = false, approved = false))
    # Penyetuju = pembuat juga ditolak (CHECK di akad, bukan hanya di versi produk).
    expectDbError(proc() =
      db.exec(sql"""
        INSERT INTO lending.loan
          (loan_id, party_id, product_version_id, branch_id, principal, status, applied_by, approved_by)
        VALUES (?, ?, ?, ?, 1000.00, 'APPROVED', ?, ?)
      """, $loanId(), $partyRow.partyId, $v, $branch, $maker, $maker))

  test "pinjaman berjalan wajib punya tanggal cair":
    let
      v = newProductVersion(some(approver))
      l = loanId()
    expectDbError(proc() = insertLoan(l, v, "ACTIVE", disbursed = false, approved = true))
    insertLoan(l, v, "ACTIVE", disbursed = true, approved = true)
    check db.getValue(sql"SELECT disbursed_on::text FROM lending.loan WHERE loan_id = ?", $l) ==
      "2026-11-01"

  test "pokok harus positif dan saldo cache tidak boleh negatif":
    let
      v = newProductVersion(some(approver))
      l = loanId()
    expectDbError(proc() =
      db.exec(sql"""
        INSERT INTO lending.loan
          (loan_id, party_id, product_version_id, branch_id, principal, status, disbursed_on, applied_by, approved_by)
        VALUES (?, ?, ?, ?, 0.00, 'ACTIVE', '2026-11-01', ?, ?)
      """, $l, $partyRow.partyId, $v, $branch, $maker, $approver))
    insertLoan(l, v, "ACTIVE", disbursed = true, approved = true)
    db.exec(sql"INSERT INTO lending.loan_balance (loan_id) VALUES (?)", $l)
    expectDbError(proc() =
      db.exec(sql"UPDATE lending.loan_balance SET principal_outstanding = -1.00 WHERE loan_id = ?", $l))

suite "lending: jadwal angsuran":
  proc activeLoan(): Id =
    let
      v = newProductVersion(some(approver))
      l = loanId()
    insertLoan(l, v, "ACTIVE", disbursed = true, approved = true)
    l

  proc scheduleFor(l: Id; paidPrincipal: string = "0.00"; paidInterest: string = "0.00"): int =
    db.exec(sql"""
      INSERT INTO lending.installment
        (loan_id, no, due_on, principal_due, interest_due, penalty_due, paid_principal, paid_interest)
      VALUES (?, 1, '2026-12-01', 400000.00, 50000.00, 0.00, ?, ?)
    """, $l, paidPrincipal, paidInterest)
    1

  test "nomor jatuh tempo unik per pinjaman":
    let l = activeLoan()
    discard scheduleFor(l)
    expectDbError(proc() = discard scheduleFor(l))

  test "pembayaran tidak boleh melebihi kewajiban komponennya":
    let l = activeLoan()
    expectDbError(proc() = discard scheduleFor(l, paidPrincipal = "400000.01"))

  test "baris tanpa kewajiban ditolak":
    let l = activeLoan()
    expectDbError(proc() =
      db.exec(sql"""
        INSERT INTO lending.installment (loan_id, no, due_on, principal_due, interest_due, penalty_due)
        VALUES (?, 2, '2027-01-01', 0.00, 0.00, 0.00)
      """, $l))

  test "baris yang sudah dibayar tidak bisa diubah atau dihapus":
    let l = activeLoan()
    discard scheduleFor(l, paidPrincipal = "100000.00", paidInterest = "50000.00")
    expectDbError(proc() =
      db.exec(sql"UPDATE lending.installment SET due_on = '2027-01-01' WHERE loan_id = ? AND no = 1", $l))
    expectDbError(proc() =
      db.exec(sql"DELETE FROM lending.installment WHERE loan_id = ? AND no = 1", $l))

  test "baris belum dibayar masih bisa disesuaikan (DRAFT jadwal)":
    let l = activeLoan()
    discard scheduleFor(l)
    db.exec(sql"UPDATE lending.installment SET interest_due = 51000.00 WHERE loan_id = ? AND no = 1", $l)
    check db.getValue(sql"SELECT interest_due::text FROM lending.installment WHERE loan_id = ? AND no = 1",
      $l) == "51000.00"
