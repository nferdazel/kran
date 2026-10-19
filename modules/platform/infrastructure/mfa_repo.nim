## Repository MFA TOTP (T-046, spec §13).
##
## Waktu selalu eksplisit (`nowIso`) supaya bisa diuji deterministik; repo tidak memanggil `now()`
## sendiri. Rahasia **tidak pernah** didekripsi di sini — ciphertext diperlakukan sebagai teks
## buram; dekripsi milik lapisan layanan yang memegang `FieldCrypto`.

import std/[options, strutils]

import db_connector/db_postgres

import ./param_repo # `singleRow` (jebakan `getRow` pada nol baris, lihat catatan di sana)

type
  MfaRow* = object
    userId*: string
    methodName*: string  ## metode faktor; hanya 'TOTP' (dijaga CHECK di migrasi)
    status*: string
    secretEnc*: string
    digits*: int
    periodSeconds*: int
    lastUsedStep*: int64 ## -1 = belum pernah ada kode yang dipakai
    confirmedAt*: string ## "" bila belum dikonfirmasi

const mfaColumns = """
    user_id::text, method, status, secret_enc, digits, period_seconds,
    coalesce(last_used_step, -1),
    coalesce(to_char(confirmed_at AT TIME ZONE 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS"Z"'), '')"""

proc mfaFromRow(row: Row): MfaRow =
  MfaRow(userId: row[0], methodName: row[1], status: row[2], secretEnc: row[3],
    digits: parseInt(row[4]), periodSeconds: parseInt(row[5]),
    lastUsedStep: parseBiggestInt(row[6]).int64, confirmedAt: row[7])

proc mfaOf*(db: DbConn, userId: string): Option[MfaRow] =
  ## Pendaftaran MFA akun (PENDING maupun ACTIVE); `none` = belum pernah mendaftar.
  let found = db.singleRow(sql("SELECT " & mfaColumns &
    " FROM platform.user_mfa WHERE user_id = ?::uuid"), userId)
  if found.isNone:
    return none(MfaRow)
  some(mfaFromRow(found.get()))

proc upsertPending*(db: DbConn, userId, secretEnc: string, digits, periodSeconds: int,
                    nowIso: string): bool =
  ## Menulis pendaftaran baru berstatus PENDING; mengganti PENDING lama (rahasia lama belum pernah
  ## dikonfirmasi, jadi aman dibuang). Mengembalikan `false` bila baris **ACTIVE** sudah ada —
  ## faktor yang aktif tidak boleh diganti diam-diam lewat jalur enrolment (harus alur khusus yang
  ## belum ada, O-071).
  ##
  ## Penjagaan `WHERE status = 'PENDING'` di `DO UPDATE` menutup balapan dua permintaan enrolment:
  ## yang kalah tidak menimpa baris yang barusan dikonfirmasi.
  db.execAffectedRows(sql"""
    INSERT INTO platform.user_mfa
      (user_id, method, status, secret_enc, digits, period_seconds, updated_at)
    VALUES (?::uuid, 'TOTP', 'PENDING', ?, ?, ?, ?::timestamptz)
    ON CONFLICT (user_id) DO UPDATE SET
      secret_enc = EXCLUDED.secret_enc,
      digits = EXCLUDED.digits,
      period_seconds = EXCLUDED.period_seconds,
      status = 'PENDING',
      confirmed_at = NULL,
      last_used_step = NULL,
      updated_at = EXCLUDED.updated_at
    WHERE platform.user_mfa.status = 'PENDING'""",
    userId, secretEnc, $digits, $periodSeconds, nowIso) == 1

proc activateMfa*(db: DbConn, userId: string, step: int64, nowIso: string): bool =
  ## Mengaktifkan pendaftaran PENDING setelah kode pertama terbukti benar. `false` = tidak ada
  ## baris PENDING (sudah aktif atau dihapus di tengah jalan) — pemanggil menjawab konflik.
  db.execAffectedRows(sql"""
    UPDATE platform.user_mfa
       SET status = 'ACTIVE',
           confirmed_at = ?::timestamptz,
           last_used_step = ?,
           updated_at = ?::timestamptz
     WHERE user_id = ?::uuid AND status = 'PENDING'""",
    nowIso, $step, nowIso, userId) == 1

proc recordUsedStep*(db: DbConn, userId: string, step: int64, nowIso: string): bool =
  ## Mencatat langkah waktu yang dipakai (anti-replay). `false` = langkah itu sudah pernah dipakai
  ## (atau bukan baris ACTIVE), sehingga kode yang sama tidak bisa dipakai dua kali.
  ##
  ## Belum dipanggil jalur HTTP mana pun pada task ini (verifikasi hanya untuk aktivasi, yang
  ## memakai `activateMfa`); disiapkan untuk aktivasi MFA di jalur login (O-071).
  db.execAffectedRows(sql"""
    UPDATE platform.user_mfa
       SET last_used_step = ?, updated_at = ?::timestamptz
     WHERE user_id = ?::uuid AND status = 'ACTIVE'
       AND (last_used_step IS NULL OR last_used_step < ?)""",
    $step, nowIso, userId, $step) == 1
