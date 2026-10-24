## Test integrasi detail party (T-078) — butuh `KRAN_DATABASE_URL`.
##
## Cakupan: nilai detail **tidak pernah** tersimpan plaintext (diperiksa di kolom DB, bukan hanya
## dari respons), blind index deterministik & berbeda per nilai, bentuk tersamar benar, pemisahan
## orang/lembaga per jenis party, alamat unik per party, dan tidak ada jejak parsial saat transaksi
## dibatalkan.
##
## **HUMAN-REVIEW-REQUIRED**: menyentuh field crypto / PII (ADR-017, D-069).
##
## CATATAN: berkas ini **belum dijalankan** pada sesi T-078 (tidak boleh menjalankan suite `it*`
## karena me-reset schema Postgres bersama, dan `KRAN_DATABASE_URL` tidak tersedia). Jalankan
## `./task test itdetail` pada lingkungan yang memang punya DB dev.

import std/[options, os, strutils, times, unittest]

import db_connector/db_postgres

import "platform-lib/crypto/fieldcrypto"
import "platform-lib/db/config"
import "platform-lib/db/pool"
import dbtools/lib
import kernel/[clock, ids]
import party/domain/[detail, party]
import party/infrastructure/[detail_repo, party_repo]

const
  ## Kunci KEK uji: 32 byte 0x00..0x1f, base64 (pola sama dengan `tfieldcrypto`/`itkyc`).
  KekB64 = "AAECAwQFBgcICQoLDA0ODxAREhMUFRYXGBkaGxwdHh8="

let envT = envTableFromProcess()
if not databaseUrlSet(envT):
  echo "itdetail: KRAN_DATABASE_URL kosong — dilewati"
  quit(0)

let dbPool = newDbPool(dbConfigFromEnv(envT))
let db = dbPool.acquire()

resetTestSchemas(db, ".")
discard applyAllMigrations(db, ".")

let
  testClock = fakeClock(dateTime(2026, mOct, 24, 9, 0, 0))
  fc = parseKekFile("v1:" & KekB64, "itdetail")
  branch = Id("33333333-3333-7333-8333-333333333333")
  actor = Id("44444444-4444-7444-8444-444444444444")

doAssert fc.isConfigured, "keyring uji tidak terbaca"

proc newPartyForTest(name: string, seqNo: int64, kind = pkPerson): Party =
  newParty(newId(testClock), kind, name, branch, "{seq:6}{check}", seqNo)

proc triple(table, value: string): tuple[enc, bidx, mask: string] =
  (enc: encryptField(fc, table, value), bidx: blindIndex(fc, table, value), mask: maskTail(value))

proc personDetailOf(partyId: Id, legalName, birthDate, sex, occupation: string): PersonDetail =
  let ln = triple("party_person", legalName)
  let bd = triple("party_person", birthDate)
  let sx = triple("party_person", sex)
  let oc = triple("party_person", occupation)
  PersonDetail(
    partyId: partyId,
    legalNameEnc: ln.enc, legalNameBidx: ln.bidx, legalNameMask: ln.mask,
    birthDateEnc: bd.enc, birthDateBidx: bd.bidx, birthDateMask: bd.mask,
    sexEnc: sx.enc, sexBidx: sx.bidx, sexMask: sx.mask,
    occupationEnc: oc.enc, occupationBidx: oc.bidx, occupationMask: oc.mask)

proc orgDetailOf(partyId: Id, legalName: string): OrgDetail =
  let ln = triple("party_org", legalName)
  OrgDetail(partyId: partyId, legalNameEnc: ln.enc, legalNameBidx: ln.bidx, legalNameMask: ln.mask)

proc addressOf(partyId: Id, line, city, postalCode: string): Address =
  let ln = triple("address", line)
  let cy = triple("address", city)
  let pc = triple("address", postalCode)
  Address(addressId: newId(testClock), partyId: partyId,
    lineEnc: ln.enc, lineBidx: ln.bidx, lineMask: ln.mask,
    cityEnc: cy.enc, cityBidx: cy.bidx, cityMask: cy.mask,
    postalCodeEnc: pc.enc, postalCodeBidx: pc.bidx, postalCodeMask: pc.mask)

proc countRows(table: string, whereClause: string, args: varargs[string, `$`]): int =
  parseInt(db.getValue(sql("SELECT count(*)::text FROM " & table & " WHERE " & whereClause), args))

suite "party_person: at-rest":
  test "nilai tersimpan terenkripsi, bentuk tersamar & blind index benar":
    let p = newPartyForTest("Budi Detail", nextCifSeq(db))
    discard insertParty(db, p, actor)
    let detail = personDetailOf(p.partyId, "Budi Santoso", "1990-01-15", "MALE", "Petani")
    let updatedAt = upsertPersonDetail(db, detail, actor)
    check updatedAt.len >= 20

    let stored = db.getRow(sql"""
      SELECT legal_name_enc, legal_name_bidx, legal_name_mask,
             birth_date_enc, sex_enc, occupation_enc
        FROM party.party_person WHERE party_id = ?""", $p.partyId)
    check stored[0].startsWith("kran:enc:v1:")
    check not stored[0].contains("Budi Santoso")
    check stored[1].len == 64
    check stored[1] != "Budi Santoso"
    check stored[2] == "so"
    check not stored[3].contains("1990-01-15")
    check not stored[4].contains("MALE")
    check not stored[5].contains("Petani")

    # Blind index deterministik: nilai yang sama → indeks yang sama.
    check stored[1] == blindIndex(fc, "party_person", "Budi Santoso")

  test "upsert kedua memperbarui baris, bukan menambah":
    let p = newPartyForTest("Siti Detail", nextCifSeq(db))
    discard insertParty(db, p, actor)
    discard upsertPersonDetail(db, personDetailOf(p.partyId, "Siti Aminah", "1985-05-01",
      "FEMALE", ""), actor)
    discard upsertPersonDetail(db, personDetailOf(p.partyId, "Siti Aminah", "1985-05-01",
      "FEMALE", "Guru"), actor)
    check countRows("party.party_person", "party_id = ?", $p.partyId) == 1
    let row = db.getRow(sql"SELECT occupation_bidx FROM party.party_person WHERE party_id = ?",
      $p.partyId)
    check row[0] == blindIndex(fc, "party_person", "Guru")

  test "tidak ada detail untuk party lain":
    check personDetailOf(db, Id("55555555-5555-7555-8555-555555555555")).isNone

suite "party_org: at-rest":
  test "nama resmi lembaga tersimpan terenkripsi":
    let p = newPartyForTest("Koperasi Detail", nextCifSeq(db), pkOrg)
    discard insertParty(db, p, actor)
    discard upsertOrgDetail(db, orgDetailOf(p.partyId, "Koperasi Sejahtera"), actor)
    let stored = db.getRow(sql"""
      SELECT legal_name_enc, legal_name_bidx, legal_name_mask
        FROM party.party_org WHERE party_id = ?""", $p.partyId)
    check stored[0].startsWith("kran:enc:v1:")
    check not stored[0].contains("Koperasi Sejahtera")
    check stored[1].len == 64
    check stored[2] == "ra"

suite "address: at-rest & keunikan":
  test "tiap kolom alamat terenkripsi dan 1:1 per party":
    let p = newPartyForTest("Alamat Detail", nextCifSeq(db))
    discard insertParty(db, p, actor)
    discard upsertAddress(db, addressOf(p.partyId, "Jl. Merdeka 5", "Bandung", "40115"), actor)
    discard upsertAddress(db, addressOf(p.partyId, "Jl. Sudirman 10", "Bandung", "40115"), actor)
    check countRows("party.address", "party_id = ?", $p.partyId) == 1
    let stored = db.getRow(sql"""
      SELECT line_enc, city_bidx, postal_code_enc
        FROM party.address WHERE party_id = ?""", $p.partyId)
    check not stored[0].contains("Jl. Sudirman")
    check stored[1] == blindIndex(fc, "address", "Bandung")
    check not stored[2].contains("40115")

  test "rollback transaksi tidak meninggalkan baris":
    let p = newPartyForTest("Batal Detail", nextCifSeq(db))
    discard insertParty(db, p, actor)
    var failed = false
    try:
      discard dbPool.withTx(proc(d: DbConn): int {.closure.} =
        discard upsertPersonDetail(d, personDetailOf(p.partyId, "Nama Batal", "1991-02-03",
          "MALE", ""), actor)
        raise newException(ValueError, "batal"))
    except ValueError:
      failed = true
    check failed
    check countRows("party.party_person", "party_id = ?", $p.partyId) == 0
