## Repository audit: tulis & verifikasi rantai hash (spec §9.1(7), §18.2).
##
## Pemisahan tanggung jawab yang disengaja: **hash tidak dihitung di Nim**. Rantai dihitung
## trigger `platform.audit_log_chain` di DB supaya tidak ada jalur tulis yang bisa melewatkannya.

import std/[json, strutils]
import db_connector/db_postgres

import ../domain/audit
import kernel/[auditcontext, ids]

type
  AuditChainRow* = object
    seq*: int64
    rowHashOk*: bool ## hash baris == rekap payload baris itu
    linkOk*: bool    ## prev_hash baris == hash baris sebelumnya
    expectedHash*: string
    actualHash*: string

proc jsonOrNull(n: JsonNode): string =
  if n.isNil: "null" else: $n

proc appendAudit*(db: DbConn, entry: AuditEntry): string =
  ## Menyisipkan satu entri audit dan mengembalikan hash yang dihitung DB.
  ## Raise `DbError` bila melanggar skema (kolom wajib, ip/date tidak valid).
  db.getValue(
    sql"""INSERT INTO platform.audit_log
            (audit_id, business_date, actor_user_id, actor_role, branch_id, request_id,
             client_ip, device, action, resource_type, resource_id, reason,
             before_value, after_value)
          VALUES
            (?, NULLIF(?, '')::date, NULLIF(?, '')::uuid, NULLIF(?, ''), NULLIF(?, '')::uuid,
             NULLIF(?, ''), NULLIF(?, '')::inet, NULLIF(?, ''), ?, ?, NULLIF(?, ''),
             NULLIF(?, ''), ?::jsonb, ?::jsonb)
          RETURNING hash""",
    $entry.auditId, entry.businessDate, $entry.ctx.userId, entry.role, $entry.primaryBranch(),
    entry.ctx.correlationId, entry.ctx.ip, entry.ctx.device, entry.action, entry.resourceType,
    entry.resourceId, entry.ctx.reason, jsonOrNull(entry.before), jsonOrNull(entry.after))

proc verifyChain*(db: DbConn, fromSeq = 0'i64): seq[AuditChainRow] =
  ## Memeriksa seluruh rantai (atau dari `fromSeq`). `rowHashOk`/`linkOk` keduanya harus true.
  for row in db.getAllRows(
      sql"""SELECT seq, row_hash_ok, link_ok, expected_hash, actual_hash
            FROM platform.audit_verify(?)""", $fromSeq):
    result.add AuditChainRow(
      seq: parseBiggestInt(row[0]),
      rowHashOk: row[1] == "t",
      linkOk: row[2] == "t",
      expectedHash: row[3],
      actualHash: row[4])

proc chainOk*(rows: openArray[AuditChainRow]): bool =
  for r in rows:
    if not (r.rowHashOk and r.linkOk):
      return false
  true

proc countAudit*(db: DbConn): int64 =
  parseBiggestInt(db.getValue(sql"SELECT count(*) FROM platform.audit_log"))
