## Repositori KYC/dokumen identitas modul `party` (T-071). SQL murni.
##
## Tidak ada aturan bisnis maupun kriptografi di sini: nomor datang sudah berbentuk ciphertext +
## blind index dari composition root (kepemilikan kunci = urusan platform, ADR-017). Modul ini
## juga tidak mengimpor internal `platform` (archcheck rule C) — audit/outbox ditulis pemanggil.

import std/options

import db_connector/db_postgres

import kernel/ids
import ../domain/[identity, kyc]

const
  ## Batas baris riwayat/dokumen yang dikembalikan daftar. Angka **teknis** (pertahanan terhadap
  ## permintaan besar), bukan ambang bisnis.
  listLimit* = 50 # nomagic:ok batas ukuran respons, bukan nilai bisnis

## Kolom dokumen dalam urutan tetap yang dipakai semua SELECT di berkas ini.
const docColumns =
  """
    doc_id, party_id, doc_type, number_enc, number_bidx, number_last2,
    coalesce(to_char(issued_at, 'YYYY-MM-DD'), ''),
    coalesce(to_char(expires_at, 'YYYY-MM-DD'), ''),
    to_char(created_at AT TIME ZONE 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS"Z"')"""

proc docOf(row: Row): IdentityDoc =
  IdentityDoc(
    docId: Id(row[0]),
    partyId: Id(row[1]),
    docType: row[2],
    numberEnc: row[3],
    numberBidx: row[4],
    numberLast2: row[5],
    issuedAt: row[6],
    expiresAt: row[7],
    createdAt: row[8],
  )

proc insertIdentityDoc*(db: DbConn, doc: IdentityDoc, createdBy: Id): string =
  ## Menyisipkan dokumen (nomor sudah terenkripsi) dan mengembalikan `created_at` ISO-8601 UTC.
  ## Melanggar `identity_doc_number_uq` = `DbError` yang oleh pemanggil diterjemahkan jadi 409.
  db.getValue(sql"""
    INSERT INTO party.identity_doc
      (doc_id, party_id, doc_type, number_enc, number_bidx, number_last2,
       issued_at, expires_at, created_by, updated_by)
    VALUES (?, ?, ?, ?, ?, ?, NULLIF(?, '')::date, NULLIF(?, '')::date, ?, ?)
    RETURNING to_char(created_at AT TIME ZONE 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS"Z"')""",
    $doc.docId, $doc.partyId, doc.docType, doc.numberEnc, doc.numberBidx, doc.numberLast2,
    doc.issuedAt, doc.expiresAt, $createdBy, $createdBy)

proc identityDocByNumber*(db: DbConn, docType, numberBidx: string): Option[IdentityDoc] =
  ## Mencari dokumen lewat blind index — satu-satunya cara mencari nomor terenkripsi.
  let rows = db.getAllRows(sql("SELECT " & docColumns &
    " FROM party.identity_doc WHERE doc_type = ? AND number_bidx = ?"),
    docType, numberBidx)
  if rows.len == 0:
    return none(IdentityDoc)
  some(docOf(rows[0]))

proc identityDocById*(db: DbConn, docId: Id): Option[IdentityDoc] =
  let rows = db.getAllRows(sql("SELECT " & docColumns &
    " FROM party.identity_doc WHERE doc_id = ?"), $docId)
  if rows.len == 0:
    return none(IdentityDoc)
  some(docOf(rows[0]))

proc identityDocsOf*(db: DbConn, partyId: Id, limit = listLimit): seq[IdentityDoc] =
  for row in db.getAllRows(sql("SELECT " & docColumns &
      " FROM party.identity_doc WHERE party_id = ? ORDER BY created_at, doc_id LIMIT ?::int"),
      $partyId, $limit):
    result.add docOf(row)

proc insertKycProfile*(db: DbConn, partyId: Id, riskLevel, nextReviewDue: string,
                       createdBy: Id): string =
  ## Profil KYC awal party (dibuat bersama party, transaksi yang sama). Mengembalikan `created_at`.
  db.getValue(sql"""
    INSERT INTO party.kyc_profile
      (party_id, status, risk_level, next_review_due, created_by, updated_by)
    VALUES (?, 'PENDING', ?, NULLIF(?, '')::date, ?, ?)
    RETURNING to_char(created_at AT TIME ZONE 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS"Z"')""",
    $partyId, riskLevel, nextReviewDue, $createdBy, $createdBy)

proc kycProfileOf*(db: DbConn, partyId: Id): Option[KycProfile] =
  let rows = db.getAllRows(sql"""
    SELECT party_id, status, risk_level,
           coalesce(to_char(risk_assessed_at AT TIME ZONE 'UTC',
                            'YYYY-MM-DD"T"HH24:MI:SS"Z"'), ''),
           coalesce(to_char(next_review_due, 'YYYY-MM-DD'), ''),
           to_char(created_at AT TIME ZONE 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS"Z"')
      FROM party.kyc_profile WHERE party_id = ?""", $partyId)
  if rows.len == 0:
    return none(KycProfile)
  let row = rows[0]
  let status = parseKycStatus(row[1])
  if status.isNone:
    raise newException(ValueError, "status KYC di DB tidak dikenal: " & row[1])
  some(KycProfile(
    partyId: Id(row[0]),
    status: status.get(),
    riskLevel: row[2],
    riskAssessedAt: row[3],
    nextReviewDue: row[4],
    createdAt: row[5],
  ))

proc applyRiskAssessment*(db: DbConn, partyId: Id, level, nextReviewDue: string,
                          updatedBy: Id, assessedAt: string) =
  ## Menjadikan penilaian risiko terbaru sebagai rating berjalan di profil KYC. `assessedAt`
  ## dikirim pemanggil supaya profil dan baris riwayat memakai **satu** cap waktu yang sama.
  let rows = db.getAllRows(sql"""
    UPDATE party.kyc_profile
       SET risk_level = ?, risk_assessed_at = ?::timestamptz,
           next_review_due = NULLIF(?, '')::date,
           updated_at = now(), updated_by = ?
     WHERE party_id = ?
    RETURNING party_id""",
    level, assessedAt, nextReviewDue, $updatedBy, $partyId)
  if rows.len == 0:
    raise newException(ValueError, "profil KYC party tidak ditemukan")

proc insertRiskAssessment*(db: DbConn, a: RiskAssessment): string =
  ## Menambah satu baris riwayat (append-only) dan mengembalikan `assessed_at` ISO-8601 UTC.
  db.getValue(sql"""
    INSERT INTO party.risk_rating (rating_id, party_id, level, reason, assessed_at, assessed_by)
    VALUES (?, ?, ?, ?, now(), ?)
    RETURNING to_char(assessed_at AT TIME ZONE 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS"Z"')""",
    $a.ratingId, $a.partyId, a.level, a.reason, $a.assessedBy)

proc riskAssessmentsOf*(db: DbConn, partyId: Id, limit = listLimit): seq[RiskAssessment] =
  ## Riwayat penilaian, terbaru lebih dulu — dibaca auditor/petugas, bukan untuk perhitungan.
  for row in db.getAllRows(sql"""
    SELECT rating_id, party_id, level, reason,
           to_char(assessed_at AT TIME ZONE 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS"Z"'),
           assessed_by
      FROM party.risk_rating WHERE party_id = ?
     ORDER BY assessed_at DESC, rating_id DESC LIMIT ?::int""", $partyId, $limit):
    result.add RiskAssessment(
      ratingId: Id(row[0]),
      partyId: Id(row[1]),
      level: row[2],
      reason: row[3],
      assessedAt: row[4],
      assessedBy: row[5],
    )
