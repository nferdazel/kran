## Test integrasi KYC/dokumen identitas (T-071) — butuh `KRAN_DATABASE_URL`.
##
## Cakupan: nomor dokumen **tidak pernah** tersimpan plaintext (diperiksa di kolom DB, bukan hanya
## dari respons), blind index deterministik & unik, duplikat ditolak DB, profil + riwayat risiko
## append-only, dan tidak ada jejak parsial saat transaksi dibatalkan.
##
## Test ini memakai `parseKekFile` langsung (kunci uji 32 byte 0x00..0x1f) supaya tidak bergantung
## pada berkas/mode 600; jalur berkas KEK sungguhan diuji `tfieldcrypto` + `itapi_mfa`.

import std/[json, options, os, strutils, times, unittest]

import db_connector/db_postgres

import "platform-lib/crypto/fieldcrypto"
import "platform-lib/db/config"
import "platform-lib/db/pool"
import dbtools/lib
import kernel/[clock, ids]
import party/domain/[identity, kyc, party]
import party/infrastructure/[kyc_repo, party_repo]

const
  ## Kunci KEK uji: 32 byte 0x00..0x1f, base64 (pola sama dengan `tfieldcrypto`).
  KekB64 = "AAECAwQFBgcICQoLDA0ODxAREhMUFRYXGBkaGxwdHh8="

let envT = envTableFromProcess()
if not databaseUrlSet(envT):
  echo "itkyc: KRAN_DATABASE_URL kosong — dilewati"
  quit(0)

let dbPool = newDbPool(dbConfigFromEnv(envT))
let db = dbPool.acquire()

discard applyMigrations(db, ".")
db.exec(sql"DROP SCHEMA IF EXISTS party CASCADE")
db.exec(sql"DELETE FROM platform.schema_migration WHERE migration_id LIKE 'party/%'")
discard applyMigrations(db, ".")

let
  testClock = fakeClock(dateTime(2026, mOct, 19, 9, 0, 0))
  fc = parseKekFile("v1:" & KekB64, "itkyc")
  branch = Id("33333333-3333-7333-8333-333333333333")
  actor = Id("44444444-4444-7444-8444-444444444444")

doAssert fc.isConfigured, "keyring uji tidak terbaca"

proc newPartyForTest(name: string, seqNo: int64): Party =
  newParty(newId(testClock), pkPerson, name, branch, "{seq:6}{check}", seqNo)

proc addDoc(partyId: Id, docType, number: string): IdentityDoc =
  ## Membuat dokumen terenkripsi lewat jalur yang sama dengan handler (enkripsi + blind index).
  let normalized = normalizeNumber(number)
  IdentityDoc(
    docId: newId(testClock),
    partyId: partyId,
    docType: docType,
    numberEnc: encryptField(fc, "identity_doc", normalized),
    numberBidx: blindIndex(fc, "identity_doc", normalized),
    numberLast2: maskNumber(normalized),
    issuedAt: "",
    expiresAt: "",
    createdAt: "")

proc countRows(table: string, whereClause: string, args: varargs[string, `$`]): int =
  parseInt(db.getValue(sql("SELECT count(*)::text FROM " & table & " WHERE " & whereClause), args))

suite "identity_doc: at-rest & duplikat":
  test "nomor tersimpan terenkripsi, bukan plaintext":
    let p = newPartyForTest("Budi KYC", nextCifSeq(db))
    discard insertParty(db, p, actor)
    var doc = addDoc(p.partyId, "KTP", "3201234567890001")
    doc.createdAt = insertIdentityDoc(db, doc, actor)

    let stored = db.getRow(sql"""
      SELECT number_enc, number_bidx, number_last2, length(number_enc)::text
        FROM party.identity_doc WHERE doc_id = ?""", $doc.docId)
    check stored[0].startsWith("kran:enc:v1:")
    check not stored[0].contains("3201234567890001")
    check stored[1].len == 64
    check stored[1] != "3201234567890001"
    check stored[2] == "01"
    # Nomor asli (16 digit) tidak mungkin lebih pendek dari ciphertext-nya.
    check parseInt(stored[3]) > "3201234567890001".len

    let found = identityDocByNumber(db, "KTP", blindIndex(fc, "identity_doc", "3201234567890001"))
    check found.isSome
    check found.get().docId == doc.docId

  test "blind index berbeda untuk nomor berbeda, sama untuk nomor sama":
    let a = blindIndex(fc, "identity_doc", "3201234567890002")
    let b = blindIndex(fc, "identity_doc", "3201234567890003")
    check a != b
    check a == blindIndex(fc, "identity_doc", "3201234567890002")

  test "nomor ganda ditolak DB (constraint unik)":
    let p = newPartyForTest("Siti KYC", nextCifSeq(db))
    discard insertParty(db, p, actor)
    let first = addDoc(p.partyId, "KTP", "3201234567890009")
    discard insertIdentityDoc(db, first, actor)

    let p2 = newPartyForTest("Agus KYC", nextCifSeq(db))
    discard insertParty(db, p2, actor)
    let second = addDoc(p2.partyId, "KTP", "3201234567890009")
    var raised = false
    try:
      discard insertIdentityDoc(db, second, actor)
    except DbError:
      raised = true
    check raised
    # Yang gagal tidak meninggalkan baris apa pun.
    check countRows("party.identity_doc", "doc_id = ?", $second.docId) == 0

  test "keunikan berlaku per jenis dokumen (batas yang disengaja)":
    # Constraint unik = (doc_type, number_bidx): nomor yang sama di **jenis berbeda** bukan
    # duplikat (jenis dokumen punya ruang nomor sendiri). Dokumentasi menyebut batas ini.
    let p = newPartyForTest("Multi Dokumen", nextCifSeq(db))
    discard insertParty(db, p, actor)
    var ktp = addDoc(p.partyId, "KTP", "3201234567890099")
    ktp.createdAt = insertIdentityDoc(db, ktp, actor)
    var npwp = addDoc(p.partyId, "NPWP", "3201234567890099")
    npwp.createdAt = insertIdentityDoc(db, npwp, actor)
    check identityDocsOf(db, p.partyId).len == 2
    check identityDocByNumber(db, "KTP", ktp.numberBidx).isSome
    check identityDocByNumber(db, "NPWP", npwp.numberBidx).isSome

  test "dokumen & profil party berbeda tidak saling bocor":
    let p = newPartyForTest("Koperasi KYC", nextCifSeq(db))
    discard insertParty(db, p, actor)
    let doc = addDoc(p.partyId, "NPWP", "012345678901234")
    discard insertIdentityDoc(db, doc, actor)

    let docs = identityDocsOf(db, p.partyId)
    check docs.len == 1
    check docs[0].docType == "NPWP"
    check docs[0].numberLast2 == "34"
    check identityDocsOf(db, Id("55555555-5555-7555-8555-555555555555")).len == 0

suite "kyc_profile & risk_rating":
  test "profil awal + penilaian risiko memperbarui rating berjalan":
    let p = newPartyForTest("Rina KYC", nextCifSeq(db))
    discard insertParty(db, p, actor)
    let createdAt = insertKycProfile(db, p.partyId, "LOW", "2029-10-19", actor)
    check createdAt.len >= 20

    var profile = kycProfileOf(db, p.partyId).get()
    check profile.status == ksPending
    check profile.riskLevel == "LOW"
    check profile.riskAssessedAt.len == 0
    check profile.nextReviewDue == "2029-10-19"

    var assessment = RiskAssessment(
      ratingId: newId(testClock),
      partyId: p.partyId,
      level: "HIGH",
      reason: "transaksi tidak wajar",
      assessedAt: "",
      assessedBy: $actor)
    assessment.assessedAt = insertRiskAssessment(db, assessment)
    applyRiskAssessment(db, p.partyId, "HIGH", reviewDueDate("2026-10-19", 6), actor,
      assessment.assessedAt)

    profile = kycProfileOf(db, p.partyId).get()
    check profile.riskLevel == "HIGH"
    check profile.riskAssessedAt == assessment.assessedAt
    check profile.nextReviewDue == "2027-04-19"

    let history = riskAssessmentsOf(db, p.partyId)
    check history.len == 1
    check history[0].level == "HIGH"
    check history[0].reason == "transaksi tidak wajar"
    check history[0].assessedAt == assessment.assessedAt

  test "riwayat risiko append-only (UPDATE/DELETE ditolak DB)":
    let p = newPartyForTest("Tono KYC", nextCifSeq(db))
    discard insertParty(db, p, actor)
    discard insertKycProfile(db, p.partyId, "LOW", "", actor)
    var assessment = RiskAssessment(
      ratingId: newId(testClock), partyId: p.partyId, level: "MEDIUM", reason: "uji",
      assessedAt: "", assessedBy: $actor)
    assessment.assessedAt = insertRiskAssessment(db, assessment)

    var updateRejected, deleteRejected = false
    try:
      db.exec(sql"UPDATE party.risk_rating SET level = 'LOW' WHERE rating_id = ?",
          $assessment.ratingId)
    except DbError:
      updateRejected = true
    try:
      db.exec(sql"DELETE FROM party.risk_rating WHERE rating_id = ?", $assessment.ratingId)
    except DbError:
      deleteRejected = true
    check updateRejected
    check deleteRejected
    check countRows("party.risk_rating", "rating_id = ?", $assessment.ratingId) == 1

  test "rollback transaksi tidak meninggalkan dokumen":
    let p = newPartyForTest("Batal KYC", nextCifSeq(db))
    discard insertParty(db, p, actor)
    let doc = addDoc(p.partyId, "KTP", "3201234567890011")

    var failed = false
    try:
      discard dbPool.withTx(proc(d: DbConn): int {.closure.} =
        discard insertIdentityDoc(d, doc, actor)
        raise newException(ValueError, "batal"))
    except ValueError:
      failed = true
    check failed
    check countRows("party.identity_doc", "doc_id = ?", $doc.docId) == 0
    check identityDocByNumber(db, "KTP", doc.numberBidx).isNone
