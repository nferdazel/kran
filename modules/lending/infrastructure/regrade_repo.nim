## Repositori penilaian kolektibilitas (T-166). SQL murni; aturan golongan ada di domain.
##
## Kandidat diambil per halaman **dari populasi stabil** (`ACTIVE`), bukan dari jumlah yang akan
## berubah: jumlah yang berubah baru diketahui setelah DPD dihitung per pinjaman, dan halaman yang
## dihitung dari perkiraan berarti pinjaman di ujung daftar tidak pernah dinilai.

import std/[options, strutils]

import db_connector/db_postgres

import kernel/ids
import ../domain/collectibility

type
  RegradeCandidate* = object
    loanId*: Id
    previous*: Option[Collectibility] ## `none` = belum pernah dinilai
    oldestUnpaidDue*: string          ## `""` = tidak ada angsuran yang belum lunas

proc countActiveLoans*(db: DbConn): int64 =
  parseBiggestInt(db.getValue(sql"SELECT count(*) FROM lending.loan WHERE status = 'ACTIVE'"))

proc regradeCandidatesPage*(db: DbConn; offset, limit: int): seq[RegradeCandidate] =
  ## `paid_on` kosong berarti angsuran belum lunas (diisi `markSettledRows` hanya saat semua
  ## komponen tertutup), jadi `min(due_on)` di antaranya adalah tanggal tunggakan tertua.
  ## Baris yang diarsipkan restrukturisasi tidak dihitung: kewajibannya sudah digantikan jadwal baru,
  ## dan menghitungnya membuat DPD tetap menunggak tepat setelah restrukturisasi — berlawanan dengan
  ## keputusan "kembali lancar" (D-186, O-123).
  for row in db.getAllRows(sql"""
    SELECT l.loan_id::text, coalesce(l.collectibility, ''),
           coalesce(min(i.due_on) FILTER (WHERE i.paid_on IS NULL AND i.superseded_on IS NULL)::text,
                    '')
      FROM lending.loan l
      LEFT JOIN lending.installment i ON i.loan_id = l.loan_id
     WHERE l.status = 'ACTIVE'
     GROUP BY l.loan_id, l.collectibility
     ORDER BY l.loan_id
     LIMIT ? OFFSET ?""", limit, offset):
    result.add RegradeCandidate(
      loanId: Id(row[0]),
      previous: (if row[1].len == 0: none(Collectibility) else: parseCollectibility(row[1])),
      oldestUnpaidDue: row[2],
    )

proc insertSnapshot*(db: DbConn; loanId: Id; businessDate: string; dpd: int;
    grade: Collectibility): bool =
  ## `false` = penilaian tanggal itu sudah ada (task dijalankan ulang) — bukan galat, dan bukan
  ## alasan menimpa nilai historis.
  db.execAffectedRows(sql"""
    INSERT INTO lending.collectibility_snapshot (loan_id, business_date, dpd, grade)
    VALUES (?, ?::date, ?, ?)
    ON CONFLICT (loan_id, business_date) DO NOTHING""",
    $loanId, businessDate, dpd, $grade) == 1

proc updateCollectibility*(db: DbConn; loanId: Id; grade: Collectibility) =
  db.exec(sql"UPDATE lending.loan SET collectibility = ? WHERE loan_id = ?", $grade, $loanId)
