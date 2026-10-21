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
    ## `decision == idemProceed` berarti klaim baru (atau baris lama yang sudah kedaluwarsa
    ## diganti); pemanggil wajib menjalankan operasi lalu memanggil `completeIdempotency`
    ## sebelum COMMIT.
    decision*: IdempotencyDecision
    status*: int ## status tersimpan; hanya untuk `idemReplay`
    body*: string ## JSON tersimpan; hanya untuk `idemReplay`
    expiresAt*: string ## ISO UTC; dipakai pemanggil untuk menghitung `Retry-After`

const expiresAtSelect = """
  to_char(expires_at AT TIME ZONE 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS"Z"')"""

proc claimIdempotency*(db: DbConn, principalId, key, operationId, fingerprint,
    createdAtIso, nowIso, expiresAtIso: string): IdempotencyClaim =
  ## Baris kedaluwarsa diperlakukan sebagai tidak ada: dihapus dulu, lalu klaim baru dibuat.
  ## Tanpa ini, TTL hanya berlaku kalau daycloser kebetulan sudah berjalan (D-098).
  discard db.execAffectedRows(sql"""
    DELETE FROM platform.idempotency_key
    WHERE principal_id = ?::uuid AND key = ? AND expires_at <= ?::timestamptz""",
    principalId, key, nowIso)

  let inserted = db.execAffectedRows(sql"""
    INSERT INTO platform.idempotency_key
      (principal_id, key, operation_id, request_hash, created_at, expires_at)
    VALUES (?::uuid, ?, ?, ?, ?::timestamptz, ?::timestamptz)
    ON CONFLICT (principal_id, key) DO NOTHING""",
    principalId, key, operationId, fingerprint, createdAtIso, expiresAtIso) == 1
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
    # Baris hilang di antara INSERT dan SELECT (disapu proses lain). Perlakuan paling aman:
    # minta pemanggil mencoba lagi, bukan menjalankan operasi bisnis tanpa klaim. `expiresAt`
    # kosong membuat helper memakai `Retry-After` minimum (1 detik), bukan satu TTL penuh.
    return IdempotencyClaim(decision: idemInFlight)

  if row[0] != operationId or row[1] != fingerprint:
    return IdempotencyClaim(decision: idemMismatch, expiresAt: row[4])

  if row[2].len == 0:
    return IdempotencyClaim(decision: idemInFlight, expiresAt: row[4])

  IdempotencyClaim(decision: idemReplay, status: parseInt(row[2]), body: row[3],
    expiresAt: row[4])

proc completeIdempotency*(db: DbConn, principalId, key, completedAtIso: string, status: int,
    body: string): bool =
  ## Menutup klaim dengan respons sukses pada waktu yang dikirim pemanggil (jam yang sama dengan
  ## klaim, sehingga test memakai jam tetap). `false` = klaim tidak ada/sudah tertutup — bug
  ## pemanggil, bukan kondisi normal.
  db.execAffectedRows(sql"""
    UPDATE platform.idempotency_key
    SET response_status = ?, response_body = ?::jsonb, completed_at = ?::timestamptz
    WHERE principal_id = ?::uuid AND key = ? AND response_status IS NULL""",
    status, body, completedAtIso, principalId, key) == 1

proc idempotencyCount*(db: DbConn, principalId: string): int64 =
  ## Untuk test: jumlah baris klaim milik satu principal.
  parseBiggestInt(db.getValue(
    sql"SELECT count(*) FROM platform.idempotency_key WHERE principal_id = ?::uuid",
    principalId))
