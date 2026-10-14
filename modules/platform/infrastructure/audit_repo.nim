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

  AuditListItem* = object
    ## Satu baris audit untuk ditampilkan (UI audit trail, spec §21.4). Isinya subset kolom yang
    ## boleh dibaca peran admin; nilai mentah `before`/`after` ikut karena audit memang catatan
    ## lengkap (`afterValue` nil bila tidak ada).
    seq*: int64
    recordedAt*: string ## ISO-8601 UTC
    businessDate*: string
    actorUserId*: string
    actorRole*: string
    action*: string
    resourceType*: string
    resourceId*: string
    reason*: string
    afterValue*: JsonNode

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

proc listAudit*(db: DbConn, limit: int, action = ""): seq[AuditListItem] =
  ## Daftar audit terbaru (urut `seq` menurun). `action` kosong = semua action; pencocokan
  ## memakai **awalan** supaya `param.` bisa menyeleksi satu keluarga aksi.
  ##
  ## Batas jumlah baris wajib ada: tabel audit tidak pernah dipangkas, jadi daftar tanpa batas
  ## akan tumbuh tanpa kendali. Pemanggil (HTTP) yang menetapkan nilainya.
  for row in db.getAllRows(sql"""
    SELECT seq::text,
           to_char(recorded_at AT TIME ZONE 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS"Z"'),
           coalesce(to_char(business_date, 'YYYY-MM-DD'), ''),
           coalesce(actor_user_id::text, ''), coalesce(actor_role, ''),
           action, coalesce(resource_type, ''), coalesce(resource_id, ''),
           coalesce(reason, ''), coalesce(after_value::text, 'null')
      FROM platform.audit_log
     WHERE (?::text = '' OR action LIKE ? || '%')
     ORDER BY seq DESC
     LIMIT ?::int""", action, action, $limit):
    result.add AuditListItem(
      seq: parseBiggestInt(row[0]),
      recordedAt: row[1],
      businessDate: row[2],
      actorUserId: row[3],
      actorRole: row[4],
      action: row[5],
      resourceType: row[6],
      resourceId: row[7],
      reason: row[8],
      afterValue: parseJson(row[9]))
