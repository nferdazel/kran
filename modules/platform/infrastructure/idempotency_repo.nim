## Penyimpanan klaim Idempotency-Key (T-084, D-098).
##
## Dipanggil **di dalam transaksi bisnis** pemanggil: `claimIdempotency` menulis baris klaim,
## `completeIdempotency` menutupnya dengan respons 2xx. Tidak ada `BEGIN`/`COMMIT` di sini —
## kalau operasi bisnis gagal, klaim ikut hilang bersama transaksinya.
##
## Waktu dikirim sebagai string UTC bentuk tetap (`...Z`) mengikuti konvensi repositori lain,
## supaya test memakai jam palsu dan tidak bergantung pada `now()` di SQL.

import std/strutils
import db_connector/db_postgres

import ../domain/idempotency

type
  IdempotencyClaim* = object
    ## `decision == idemProceed` berarti baris klaim baru dibuat; pemanggil wajib menjalankan
    ## operasi lalu memanggil `completeIdempotency` sebelum COMMIT.
    decision*: IdempotencyDecision
    status*: int ## hanya untuk `idemReplay`
    body*: string ## JSON tersimpan; hanya untuk `idemReplay`
    expiresAt*: string ## ISO UTC; dipakai pemanggil untuk menghitung `Retry-After`

const expiresAtSelect = """
  to_char(expires_at AT TIME ZONE 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS"Z"')"""

proc claimIdempotency*(db: DbConn,
    principalId, key, operationId, fingerprint, expiresAtIso: string): IdempotencyClaim =
  ## `true` = klaim baru; `false` = sudah ada (replay/konflik). Baris yang belum selesai
  ## (mis. proses sebelumnya mati setelah COMMIT klaim) dilaporkan `idemInFlight`.
  let inserted = db.execAffectedRows(sql"""
    INSERT INTO platform.idempotency_key
      (principal_id, key, operation_id, request_hash, expires_at)
    VALUES (?::uuid, ?, ?, ?, ?::timestamptz)
    ON CONFLICT (principal_id, key) DO NOTHING""",
    principalId, key, operationId, fingerprint, expiresAtIso) == 1
  if inserted:
    return IdempotencyClaim(decision: idemProceed)

  let row = db.getRow(sql("""
    SELECT operation_id, request_hash,
           coalesce(response_status::text, ''), coalesce(response_body::text, ''),
           """ & expiresAtSelect &
      """
    FROM platform.idempotency_key
    WHERE principal_id = ?::uuid AND key = ?"""), principalId, key)
  if row.len == 0:
    # Baris hilang di antara INSERT dan SELECT (daycloser menyapu baris kedaluwarsa).
    # Perlakuan paling aman: minta pemanggil mencoba lagi, bukan menjalankan operasi bisnis.
    return IdempotencyClaim(decision: idemInFlight, expiresAt: expiresAtIso)

  if row[0] != operationId or row[1] != fingerprint:
    return IdempotencyClaim(decision: idemMismatch, expiresAt: row[4])

  if row[2].len == 0:
    return IdempotencyClaim(decision: idemInFlight, expiresAt: row[4])

  IdempotencyClaim(decision: idemReplay, status: parseInt(row[2]), body: row[3],
    expiresAt: row[4])

proc completeIdempotency*(db: DbConn, principalId, key: string, status: int,
    body: string): bool =
  ## Menutup klaim dengan respons sukses. `false` = klaim tidak ditemukan/ sudah tertutup —
  ## dianggap bug pemanggil, bukan kondisi normal (klaim ditulis di transaksi yang sama).
  db.execAffectedRows(sql"""
    UPDATE platform.idempotency_key
    SET response_status = ?, response_body = ?::jsonb, completed_at = now()
    WHERE principal_id = ?::uuid AND key = ? AND response_status IS NULL""",
    status, body, principalId, key) == 1

proc idempotencyCount*(db: DbConn, principalId: string): int64 =
  ## Untuk test: jumlah baris klaim milik satu principal.
  parseBiggestInt(db.getValue(
    sql"SELECT count(*) FROM platform.idempotency_key WHERE principal_id = ?::uuid",
    principalId))
