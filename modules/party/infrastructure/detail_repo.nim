## Repositori detail party (T-078): detail orang/lembaga + alamat. SQL murni.
##
## Tidak ada aturan bisnis maupun kriptografi di sini: nilai datang sudah berbentuk ciphertext +
## blind index + bentuk tersamar dari composition root (kepemilikan kunci = urusan platform,
## ADR-017/D-069). Modul ini juga tidak mengimpor internal `platform` (archcheck rule C) —
## audit/outbox ditulis pemanggil.

import std/options

import db_connector/db_postgres

import kernel/ids
import ../domain/detail

## Kolom detail dalam urutan tetap yang dipakai semua SELECT di berkas ini.
const
  personColumns =
    """
      party_id, legal_name_enc, legal_name_bidx, legal_name_mask,
      birth_date_enc, birth_date_bidx, birth_date_mask,
      sex_enc, sex_bidx, sex_mask,
      occupation_enc, occupation_bidx, occupation_mask,
      to_char(created_at AT TIME ZONE 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS"Z"'),
      to_char(updated_at AT TIME ZONE 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS"Z"')"""
  orgColumns =
    """
      party_id, legal_name_enc, legal_name_bidx, legal_name_mask,
      to_char(created_at AT TIME ZONE 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS"Z"'),
      to_char(updated_at AT TIME ZONE 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS"Z"')"""
  addressColumns =
    """
      address_id, party_id, line_enc, line_bidx, line_mask,
      city_enc, city_bidx, city_mask,
      postal_code_enc, postal_code_bidx, postal_code_mask,
      to_char(created_at AT TIME ZONE 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS"Z"'),
      to_char(updated_at AT TIME ZONE 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS"Z"')"""
  isoUpdatedAt = "to_char(updated_at AT TIME ZONE 'UTC', 'YYYY-MM-DD\"T\"HH24:MI:SS\"Z\"')"

proc personOf(row: Row): PersonDetail =
  PersonDetail(
    partyId: Id(row[0]),
    legalNameEnc: row[1], legalNameBidx: row[2], legalNameMask: row[3],
    birthDateEnc: row[4], birthDateBidx: row[5], birthDateMask: row[6],
    sexEnc: row[7], sexBidx: row[8], sexMask: row[9],
    occupationEnc: row[10], occupationBidx: row[11], occupationMask: row[12],
    createdAt: row[13], updatedAt: row[14],
  )

proc orgOf(row: Row): OrgDetail =
  OrgDetail(
    partyId: Id(row[0]),
    legalNameEnc: row[1], legalNameBidx: row[2], legalNameMask: row[3],
    createdAt: row[4], updatedAt: row[5],
  )

proc addressOfRow(row: Row): Address =
  Address(
    addressId: Id(row[0]),
    partyId: Id(row[1]),
    lineEnc: row[2], lineBidx: row[3], lineMask: row[4],
    cityEnc: row[5], cityBidx: row[6], cityMask: row[7],
    postalCodeEnc: row[8], postalCodeBidx: row[9], postalCodeMask: row[10],
    createdAt: row[11], updatedAt: row[12],
  )

proc upsertPersonDetail*(db: DbConn, p: PersonDetail, actor: Id): string =
  ## Menyimpan detail orang (1:1 per party) dan mengembalikan `updated_at` ISO-8601 UTC.
  db.getValue(sql("""
    INSERT INTO party.party_person
      (party_id, legal_name_enc, legal_name_bidx, legal_name_mask,
       birth_date_enc, birth_date_bidx, birth_date_mask,
       sex_enc, sex_bidx, sex_mask,
       occupation_enc, occupation_bidx, occupation_mask, created_by, updated_by)
    VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
    ON CONFLICT (party_id) DO UPDATE SET
      legal_name_enc = EXCLUDED.legal_name_enc,
      legal_name_bidx = EXCLUDED.legal_name_bidx,
      legal_name_mask = EXCLUDED.legal_name_mask,
      birth_date_enc = EXCLUDED.birth_date_enc,
      birth_date_bidx = EXCLUDED.birth_date_bidx,
      birth_date_mask = EXCLUDED.birth_date_mask,
      sex_enc = EXCLUDED.sex_enc,
      sex_bidx = EXCLUDED.sex_bidx,
      sex_mask = EXCLUDED.sex_mask,
      occupation_enc = EXCLUDED.occupation_enc,
      occupation_bidx = EXCLUDED.occupation_bidx,
      occupation_mask = EXCLUDED.occupation_mask,
      updated_at = now(), updated_by = EXCLUDED.updated_by
    RETURNING """ & isoUpdatedAt),
    $p.partyId, p.legalNameEnc, p.legalNameBidx, p.legalNameMask,
    p.birthDateEnc, p.birthDateBidx, p.birthDateMask,
    p.sexEnc, p.sexBidx, p.sexMask,
    p.occupationEnc, p.occupationBidx, p.occupationMask, $actor, $actor)

proc personDetailOf*(db: DbConn, partyId: Id): Option[PersonDetail] =
  let rows = db.getAllRows(sql("SELECT " & personColumns &
    " FROM party.party_person WHERE party_id = ?"), $partyId)
  if rows.len == 0:
    return none(PersonDetail)
  some(personOf(rows[0]))

proc upsertOrgDetail*(db: DbConn, o: OrgDetail, actor: Id): string =
  ## Menyimpan detail lembaga (1:1 per party) dan mengembalikan `updated_at` ISO-8601 UTC.
  db.getValue(sql("""
    INSERT INTO party.party_org
      (party_id, legal_name_enc, legal_name_bidx, legal_name_mask, created_by, updated_by)
    VALUES (?, ?, ?, ?, ?, ?)
    ON CONFLICT (party_id) DO UPDATE SET
      legal_name_enc = EXCLUDED.legal_name_enc,
      legal_name_bidx = EXCLUDED.legal_name_bidx,
      legal_name_mask = EXCLUDED.legal_name_mask,
      updated_at = now(), updated_by = EXCLUDED.updated_by
    RETURNING """ & isoUpdatedAt),
    $o.partyId, o.legalNameEnc, o.legalNameBidx, o.legalNameMask, $actor, $actor)

proc orgDetailOf*(db: DbConn, partyId: Id): Option[OrgDetail] =
  let rows = db.getAllRows(sql("SELECT " & orgColumns &
    " FROM party.party_org WHERE party_id = ?"), $partyId)
  if rows.len == 0:
    return none(OrgDetail)
  some(orgOf(rows[0]))

proc upsertAddress*(db: DbConn, a: Address, actor: Id): string =
  ## Menyimpan alamat (sekarang 1:1 per party lewat `UNIQUE (party_id)`) dan mengembalikan
  ## `updated_at` ISO-8601 UTC. `address_id` saat update diabaikan (baris lama dipertahankan).
  db.getValue(sql("""
    INSERT INTO party.address
      (address_id, party_id, line_enc, line_bidx, line_mask,
       city_enc, city_bidx, city_mask,
       postal_code_enc, postal_code_bidx, postal_code_mask, created_by, updated_by)
    VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
    ON CONFLICT (party_id) DO UPDATE SET
      line_enc = EXCLUDED.line_enc,
      line_bidx = EXCLUDED.line_bidx,
      line_mask = EXCLUDED.line_mask,
      city_enc = EXCLUDED.city_enc,
      city_bidx = EXCLUDED.city_bidx,
      city_mask = EXCLUDED.city_mask,
      postal_code_enc = EXCLUDED.postal_code_enc,
      postal_code_bidx = EXCLUDED.postal_code_bidx,
      postal_code_mask = EXCLUDED.postal_code_mask,
      updated_at = now(), updated_by = EXCLUDED.updated_by
    RETURNING """ & isoUpdatedAt),
    $a.addressId, $a.partyId, a.lineEnc, a.lineBidx, a.lineMask,
    a.cityEnc, a.cityBidx, a.cityMask,
    a.postalCodeEnc, a.postalCodeBidx, a.postalCodeMask, $actor, $actor)

proc addressOf*(db: DbConn, partyId: Id): Option[Address] =
  let rows = db.getAllRows(sql("SELECT " & addressColumns &
    " FROM party.address WHERE party_id = ?"), $partyId)
  if rows.len == 0:
    return none(Address)
  some(addressOfRow(rows[0]))
