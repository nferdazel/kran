## Repositori penyisihan PPAP (T-167). SQL murni; tarif dan pembulatan ada di domain.
##
## Kandidat halaman menggabungkan tiga sumber yang semuanya wajib ada:
##   - kolektibilitas **tanggal buku itu** (`lending.collectibility_snapshot`, T-166) — tanpa itu
##     tarif tidak bisa dipilih, dan memakai golongan lama berarti menyisihkan dengan data kemarin;
##   - pokok berjalan (`lending.loan_balance.principal_outstanding`) — dasar penyisihan;
##   - penyisihan terakhir **sebelum** tanggal buku (`lending.ppap_snapshot`) — yang dijurnal adalah
##     selisihnya, bukan angkanya.

import std/[options, strutils]

import db_connector/db_postgres

import kernel/ids
import ../domain/collectibility

type
  PpapCandidate* = object
    loanId*: Id
    branchId*: Id
    grade*: Collectibility
    base*: string              ## pokok berjalan, teks desimal (diparse pemanggil dengan `Money`)
    previousAllowance*: string ## `"0.00"` bila belum pernah disisihkan

proc ppapCandidatesPage*(db: DbConn; businessDate: string; offset, limit: int): seq[PpapCandidate] =
  ## `branch_id` ikut dibaca karena jurnal wajib punya cabang (satu jurnal per cabang per chunk).
  for row in db.getAllRows(sql"""
    SELECT l.loan_id::text, l.branch_id::text, s.grade,
           coalesce(b.principal_outstanding, 0)::numeric(24,2)::text,
           coalesce(prev.allowance, 0)::numeric(24,2)::text
      FROM lending.loan l
      JOIN lending.collectibility_snapshot s
        ON s.loan_id = l.loan_id AND s.business_date = ?::date
      LEFT JOIN lending.loan_balance b ON b.loan_id = l.loan_id
      LEFT JOIN LATERAL (
        SELECT p.allowance FROM lending.ppap_snapshot p
         WHERE p.loan_id = l.loan_id AND p.business_date < ?::date
         ORDER BY p.business_date DESC LIMIT 1
      ) prev ON true
     WHERE l.status = 'ACTIVE'
     ORDER BY l.loan_id
     LIMIT ? OFFSET ?""", businessDate, businessDate, limit, offset):
    let grade = parseCollectibility(row[2])
    if grade.isNone:
      # CHECK DB menjaga nilai kolom; kalau ini terjadi, skema dan domain tidak sinkron — bug.
      raise newException(ValueError, "golongan kolektibilitas tidak dikenal: " & row[2])
    result.add PpapCandidate(
      loanId: Id(row[0]),
      branchId: Id(row[1]),
      grade: grade.get(),
      base: row[3],
      previousAllowance: row[4],
    )

proc countGradedLoans*(db: DbConn; businessDate: string): int64 =
  ## Populasi chunk = pinjaman `ACTIVE` yang **punya** penilaian kolektibilitas tanggal itu. Pinjaman
  ## aktif tanpa penilaian tidak masuk hitungan: task regrading yang belum jalan adalah kegagalan
  ## yang harus terlihat (`DAY-383`), bukan pinjaman yang dilewati diam-diam.
  parseBiggestInt(db.getValue(sql"""
    SELECT count(*) FROM lending.loan l
      JOIN lending.collectibility_snapshot s
        ON s.loan_id = l.loan_id AND s.business_date = ?::date
     WHERE l.status = 'ACTIVE'""", businessDate))

proc activeLoansWithoutGrade*(db: DbConn; businessDate: string): int64 =
  ## Pinjaman `ACTIVE` yang belum dinilai pada tanggal itu: prasyarat task PPAP hilang.
  parseBiggestInt(db.getValue(sql"""
    SELECT count(*) FROM lending.loan l
     WHERE l.status = 'ACTIVE'
       AND NOT EXISTS (SELECT 1 FROM lending.collectibility_snapshot s
                        WHERE s.loan_id = l.loan_id AND s.business_date = ?::date)""",
    businessDate))

proc strandedAllowances*(db: DbConn): int64 =
  ## Pinjaman yang **tidak** lagi `ACTIVE` tetapi masih menyimpan penyisihan yang belum dipakai.
  ##
  ## Hapus buku (T-168) memakai penyisihan (`lending.writeoff.allowance_applied`) sesuai nilai yang
  ## dihapus, jadi pinjaman yang sudah dihapusbukukan beres. Pinjaman yang keluar dari `ACTIVE` tanpa
  ## hapus buku masih menggantung (D-183 menolak menutup akad otomatis): task gagal terlihat, bukan
  ## menutup buku dengan CKPN yang tidak punya pemilik.
  parseBiggestInt(db.getValue(sql"""
    SELECT count(*) FROM lending.loan l
     WHERE l.status <> 'ACTIVE'
       AND coalesce((SELECT p.allowance FROM lending.ppap_snapshot p
                      WHERE p.loan_id = l.loan_id ORDER BY p.business_date DESC LIMIT 1), 0)
         > coalesce((SELECT w.allowance_applied FROM lending.writeoff w
                      WHERE w.loan_id = l.loan_id), 0)"""))

proc insertPpapSnapshot*(db: DbConn; loanId: Id; businessDate: string;
    grade: Collectibility; base, allowance: string; rateMicro: int64): bool =
  ## `false` = baris tanggal itu sudah ada (run ulang) — bukan galat, dan bukan alasan menimpa.
  db.execAffectedRows(sql"""
    INSERT INTO lending.ppap_snapshot (loan_id, business_date, grade, base_amount, rate_micro,
                                       allowance)
    VALUES (?, ?::date, ?, ?::numeric, ?, ?::numeric)
    ON CONFLICT (loan_id, business_date) DO NOTHING""",
    $loanId, businessDate, $grade, base, $rateMicro, allowance) == 1
