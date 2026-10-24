## Repositori pengajuan top-up vault (T-118): SQL murni, tanpa aturan bisnis.
##
## Alur hidup: PENDING → APPROVED/REJECTED oleh akun **lain** (CHECK `vault_topup_self_approval_chk`).
## Persetujuan menulis saldo vault + jurnal GL di transaksi yang sama dengan pemanggil, jadi repo ini
## hanya menyimpan baris pengajuan dan keputusannya.

import std/[options, strutils]

import db_connector/db_postgres

import kernel/[ids, money, result]

type
  VaultTopUpRequest* = object
    requestId*: Id
    branchId*: Id
    amount*: Money
    sourceAccount*: string
    note*: string
    status*: string
    requestedBy*: string
    decidedBy*: string ## "" = belum diputuskan
    decidedAt*: string ## "" = belum diputuskan
    decisionNote*: string
    journalId*: string ## "" = belum ada jurnal
    createdAt*: string

  NewVaultTopUpRequest* = object
    requestId*: Id
    branchId*: Id
    amount*: Money
    sourceAccount*: string
    note*: string
    requestedBy*: Id

const requestColumns = """
  request_id, branch_id, amount, source_account, note, status,
  requested_by, coalesce(decided_by::text, ''), coalesce(to_char(decided_at AT TIME ZONE 'UTC',
    'YYYY-MM-DD"T"HH24:MI:SS"Z"'), ''), coalesce(decision_note, ''),
  coalesce(journal_id::text, ''),
  to_char(created_at AT TIME ZONE 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS"Z"')"""

proc requestOf(row: Row): VaultTopUpRequest =
  let amount = moneyFromString(row[2])
  if amount.isErr:
    raise newException(ValueError, "nominal pengajuan top-up tidak sah: " & row[2])
  VaultTopUpRequest(
    requestId: Id(row[0]),
    branchId: Id(row[1]),
    amount: amount.value(),
    sourceAccount: row[3],
    note: row[4],
    status: row[5],
    requestedBy: row[6],
    decidedBy: row[7],
    decidedAt: row[8],
    decisionNote: row[9],
    journalId: row[10],
    createdAt: row[11],
  )

proc insertTopUpRequest*(db: DbConn, r: NewVaultTopUpRequest): bool =
  ## `false` bila `request_id` sudah ada (replay pembuatan) — pemanggil memutuskan responsnya.
  db.getAllRows(sql"""
    INSERT INTO teller.vault_topup_request
      (request_id, branch_id, amount, source_account, note, requested_by)
    VALUES (?, ?, ?::numeric, ?, ?, ?)
    ON CONFLICT (request_id) DO NOTHING
    RETURNING request_id""", $r.requestId, $r.branchId, r.amount.toDecimalString(),
    r.sourceAccount, r.note, $r.requestedBy).len > 0

proc topUpRequestById*(db: DbConn, requestId: Id, forUpdate = false): Option[VaultTopUpRequest] =
  ## `forUpdate` mengunci baris supaya dua persetujuan bersamaan tidak sama-sama lolos.
  let suffix = if forUpdate: " FOR UPDATE" else: ""
  let rows = db.getAllRows(sql("SELECT " & requestColumns &
    " FROM teller.vault_topup_request WHERE request_id = ?" & suffix), $requestId)
  if rows.len == 0:
    return none(VaultTopUpRequest)
  some(requestOf(rows[0]))

proc decideTopUpRequest*(db: DbConn, requestId: Id, status, decidedBy, decisionNote,
                         journalId: string): bool =
  ## Menulis keputusan **hanya** bila masih PENDING. `false` = sudah diputuskan orang lain
  ## (pemanggil membatalkan transaksi supaya saldo vault tidak berubah).
  db.getAllRows(sql"""
    UPDATE teller.vault_topup_request
       SET status = ?, decided_by = ?::uuid, decided_at = now(),
           decision_note = NULLIF(?, ''), journal_id = NULLIF(?, '')::uuid
     WHERE request_id = ? AND status = 'PENDING'
    RETURNING request_id""", status, decidedBy, decisionNote, journalId, $requestId).len > 0

proc topUpRequests*(db: DbConn, branchId: Id, status: string, limit: int): seq[VaultTopUpRequest] =
  ## Daftar pengajuan satu cabang, terbaru dulu. `status` kosong = semua status.
  let rows = db.getAllRows(sql("SELECT " & requestColumns &
      """
      FROM teller.vault_topup_request
     WHERE branch_id = ? AND (? = '' OR status = ?)
     ORDER BY created_at DESC
     LIMIT ?::int"""), $branchId, status, status, $limit)
  for row in rows:
    result.add requestOf(row)
