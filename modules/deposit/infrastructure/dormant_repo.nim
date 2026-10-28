## Repositori deteksi dormant rekening (T-138e, D-152 butir 4). SQL murni: ambang bulan dan
## keputusan status ada di composition root (`apps/api/src/daycloser_deposit.nim`).
##
## **Aktivitas diambil dari subledger, bukan dari kolom `deposit.account.last_activity`.** Kolom itu
## ada sejak `0064` tetapi tidak pernah ditulis jalur transaksi mana pun; membacanya berarti semua
## rekening terlihat tidak aktif sejak dibuka. Sumber yang dipakai di sini adalah baris yang memang
## mencatat mutasi rekening: `deposit.transaction` (tunai + perpindahan jatuh tempo) dan
## `deposit.transfer` (pemindahbukuan, kedua sisi). Satu sumber, tidak bisa melenceng dari data yang
## dipakai rekonsiliasi. Lihat D-157 dan O-111.
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

proc setAccountStatus*(db: DbConn; accountId: Id; status: AccountStatus; actor: Id) =
  ## Satu-satunya tulisan task dormant: status rekening + jejak `updated_by`. Tidak menyentuh saldo,
  ## baris transaksi, atau jurnal — menandai dormant bukan peristiwa akuntansi.
  db.exec(sql"""
    UPDATE deposit.account SET status = ?, updated_by = ?
     WHERE account_id = ?""", $status, $actor, $accountId)
