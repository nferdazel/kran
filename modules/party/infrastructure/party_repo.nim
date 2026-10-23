## Repositori `party` (T-070). SQL murni; tidak ada aturan bisnis di sini.
##
## Modul ini sengaja tidak mengimpor internal `platform` (archcheck rule C): audit dan outbox
## ditulis pemanggil (composition root `apps/api`) dalam transaksi yang sama.

import std/[json, options, strutils]

import db_connector/db_postgres

import kernel/ids
import ../domain/party

type
  PartyRow* = object
    partyId*: Id
    cif*: string
    kind*: PartyKind
    displayName*: string
    status*: PartyStatus
    branchId*: Id
    createdAt*: string

proc nextCifSeq*(db: DbConn): int64 =
  ## Nomor urut CIF berikutnya. Sequence boleh berlubang bila transaksi batal — nomor bisnis
  ## tidak boleh dipakai ulang (spec §9.1(8)).
  int64(parseInt(db.getValue(sql"SELECT nextval('party.cif_seq')::text")))

proc insertParty*(db: DbConn, p: Party, createdBy: Id): string =
  ## Menyisipkan party dan mengembalikan `created_at` (ISO-8601 UTC) untuk respons HTTP.
  db.getValue(sql"""
    INSERT INTO party.party
      (party_id, cif, kind, display_name, status, branch_id, created_by, updated_by)
    VALUES (?, ?, ?, ?, ?, ?, ?, ?)
    RETURNING to_char(created_at AT TIME ZONE 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS"Z"')""",
    $p.partyId, p.cif, $p.kind, p.displayName, $p.status, $p.branchId, $createdBy, $createdBy)

proc partyById*(db: DbConn, partyId: Id): Option[PartyRow] =
  # `getRow` mengembalikan Row berisi kolom kosong bila hasilnya nol baris (jebakan
  # db_connector), jadi "tidak ditemukan" dideteksi lewat `getAllRows`.
  let rows = db.getAllRows(sql"""
    SELECT party_id, cif, kind, display_name, status, branch_id,
           to_char(created_at AT TIME ZONE 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS"Z"')
      FROM party.party
     WHERE party_id = ?""", $partyId)
  if rows.len == 0:
    return none(PartyRow)
  let row = rows[0]
  some(PartyRow(
    partyId: Id(row[0]),
    cif: row[1],
    kind: kindOf(row[2]),
    displayName: row[3],
    status: statusOf(row[4]),
    branchId: Id(row[5]),
    createdAt: row[6],
  ))

proc searchParties*(db: DbConn, query: string, allBranches: bool,
    branches: seq[string], limit: int): seq[PartyRow] =
  ## Pencarian party untuk pemilih pemilik rekening (T-115): CIF berawalan `query` **atau** nama
  ## tampil memuat `query` (ILIKE). Bentuk ringkas (kolom sama dengan `partyById`) — tidak ada
  ## identitas/KYC di sini.
  ##
  ## Penyaringan cabang dilakukan di SQL supaya `LIMIT` berlaku **setelah** penyaringan: kalau
  ## disaring di pemanggil, baris cabang lain memakan jatah halaman dan hasil bisa tampak kosong
  ## (pola `listAudit`). `allBranches` = pemanggil memegang grant tanpa batas cabang; `branches` =
  ## cabang yang ditutup grant terbatas. Daftar cabang dioper sebagai JSONB supaya SQL tidak pernah
  ## dibangun dari nilai yang datang dari pemanggil.
  let all = if allBranches: "1" else: "0"
  var branchList: seq[string]
  for b in branches:
    branchList.add b
  let readableBranches = $ %* branchList
  for row in db.getAllRows(sql"""
    SELECT party_id, cif, kind, display_name, status, branch_id,
           to_char(created_at AT TIME ZONE 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS"Z"')
      FROM party.party
     WHERE (cif LIKE ? || '%' OR display_name ILIKE '%' || ? || '%')
       AND (?::int = 1
            OR branch_id::text IN
               (SELECT value FROM jsonb_array_elements_text(?::jsonb)))
     ORDER BY display_name, cif
     LIMIT ?::int""", query, query, all, readableBranches, $limit):
    result.add PartyRow(
      partyId: Id(row[0]),
      cif: row[1],
      kind: kindOf(row[2]),
      displayName: row[3],
      status: statusOf(row[4]),
      branchId: Id(row[5]),
      createdAt: row[6],
    )
