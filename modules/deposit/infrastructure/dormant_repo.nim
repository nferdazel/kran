## Repositori deteksi dormant rekening (T-138e, D-152 butir 4). SQL murni: ambang bulan dan
## keputusan status ada di composition root (`apps/api/src/daycloser_deposit.nim`).
##
## **Aktivitas diambil dari subledger.** Sumbernya baris yang memang mencatat mutasi rekening:
## `deposit.transaction` (tunai + perpindahan jatuh tempo) dan `deposit.transfer` (pemindahbukuan,
## kedua sisi). Satu sumber, tidak bisa melenceng dari data yang dipakai rekonsiliasi. Kolom
## `deposit.account.last_activity` yang dulu ada untuk ini sudah dibuang (D-170). Lihat D-157, O-111.
##
## **Paginasi memakai himpunan yang stabil.** Himpunan yang dipaginasi adalah rekening `ACTIVE` **dan**
## `DORMANT`; task hanya memindahkan status di antara keduanya, jadi keanggotaan himpunan tidak
## berubah selama run dan offset tidak bergeser. Rekening `CLOSED` tidak pernah masuk.

import std/strutils

import db_connector/db_postgres

import kernel/ids
import ../domain/account

type
  DormantCandidate* = object
    ## Satu rekening + hasil perbandingan aktivitas terakhirnya dengan ambang. `stale` dihitung DB
    ## (`last_at < tanggal buku - N bulan`) supaya aritmetika bulan/tanggal tidak diduplikasi di Nim.
    accountId*: Id
    status*: AccountStatus
    lastActivity*: string ## ISO `yyyy-MM-dd`; untuk metrics dan pesan operator
    stale*: bool

proc countDormantCandidates*(db: DbConn): int64 =
  ## Populasi yang dipaginasi: `ACTIVE` + `DORMANT`. Bukan "jumlah yang akan ditandai" — jumlah itu
  ## baru diketahui setelah dibandingkan dengan ambang, dan `countChunks` harus mencakup seluruh
  ## himpunan stabil supaya tidak ada halaman yang terlewat.
  int64(parseInt(db.getValue(sql"""
    SELECT count(*)::text FROM deposit.account
     WHERE status IN ('ACTIVE', 'DORMANT')""")))

proc dormantCandidatesPage*(db: DbConn; businessDate: string; afterMonths, offset, limit: int):
    seq[DormantCandidate] =
  ## Halaman populasi stabil, urut `account_id`, dengan `stale` = aktivitas terakhir lebih lama
  ## dari `afterMonths` bulan sebelum `businessDate`. `make_interval` membuat pengurangan bulan
  ## mengikuti kalender Postgres (31 Mar − 1 bulan = 28/29 Feb), bukan rata-rata 30 hari.
  let query = """
    WITH activity AS (
      SELECT a.account_id, a.status,
             greatest(a.opened_on,
                      coalesce(tx.last_date, a.opened_on),
                      coalesce(pb.last_date, a.opened_on)) AS last_at
        FROM deposit.account a
        LEFT JOIN LATERAL (
          SELECT max(t.business_date) AS last_date
            FROM deposit.transaction t
           WHERE t.account_id = a.account_id
        ) tx ON true
        LEFT JOIN LATERAL (
          SELECT max(tr.business_date) AS last_date
            FROM deposit.transfer tr
           WHERE tr.source_account_id = a.account_id
              OR tr.destination_account_id = a.account_id
        ) pb ON true
       WHERE a.status IN ('ACTIVE', 'DORMANT')
    )
    SELECT account_id::text, status, to_char(last_at, 'YYYY-MM-DD'),
           last_at < ?::date - make_interval(months => ?::int)
      FROM activity
     ORDER BY account_id
     LIMIT ?::int OFFSET ?::int"""
  for row in db.getAllRows(sql(query), businessDate, $afterMonths, $limit, $offset):
    result.add DormantCandidate(
      accountId: Id(row[0]),
      status: parseAccountStatus(row[1]),
      lastActivity: row[2],
      stale: row[3] == "t")

const
  ## Ekspresi aktivitas terakhir yang sama dengan kueri halaman. Dipakai ulang di `UPDATE` supaya
  ## keputusan status dihitung **di dalam** pernyataan tulis: setoran yang commit di antara baca
  ## halaman dan tulis tidak boleh diabaikan (review T-138e; pola yang sama dengan O-112).
  lastActivityExpr = """greatest(
        a.opened_on,
        coalesce((SELECT max(t.business_date) FROM deposit.transaction t
                   WHERE t.account_id = a.account_id), a.opened_on),
        coalesce((SELECT max(p.business_date) FROM deposit.transfer p
                   WHERE p.source_account_id = a.account_id
                      OR p.destination_account_id = a.account_id), a.opened_on))"""

proc markDormantIfStale*(db: DbConn; accountId: Id; businessDate: string; afterMonths: int;
                         actor: Id): bool =
  ## Menandai `DORMANT` **hanya bila** rekening masih `ACTIVE` dan aktivitas terakhirnya memang
  ## lebih lama dari ambang. `true` = baris berubah.
  for _ in db.getAllRows(sql("""
      UPDATE deposit.account a
         SET status = 'DORMANT', updated_by = ?, updated_at = now()
       WHERE a.account_id = ? AND a.status = 'ACTIVE'
         AND """ & lastActivityExpr &
      """ < ?::date - make_interval(months => ?::int)
      RETURNING a.account_id::text"""), $actor, $accountId, businessDate, $afterMonths):
    return true
  false

proc reactivateIfActive*(db: DbConn; accountId: Id; businessDate: string; afterMonths: int;
                         actor: Id): bool =
  ## Mengembalikan `DORMANT` ke `ACTIVE` bila rekening sudah beraktivitas lagi (D-157 butir 3).
  ## `true` = baris berubah.
  for _ in db.getAllRows(sql("""
      UPDATE deposit.account a
         SET status = 'ACTIVE', updated_by = ?, updated_at = now()
       WHERE a.account_id = ? AND a.status = 'DORMANT'
         AND """ & lastActivityExpr &
      """ >= ?::date - make_interval(months => ?::int)
      RETURNING a.account_id::text"""), $actor, $accountId, businessDate, $afterMonths):
    return true
  false
