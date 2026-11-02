## Query laporan pinjaman (T-171). SQL murni; agregasi dan keputusan bentuk ada di
## `lending/domain/report.nim`.
##
## Tiga sumber yang tidak boleh dicampur:
##   - **tunggakan** dari `lending.installment` jadwal aktif (bukan cache `loan_balance`, yang bisa
##     tertinggal dari jadwal);
##   - **penyisihan** dari `lending.ppap_snapshot` tanggal buku itu apa adanya — laporan tanggal
##     lampau tidak boleh memakai angka hari ini;
##   - **subledger** untuk rekonsiliasi: cache saldo pokok, penyisihan terakhir per pinjaman, dan
##     penyisihan yang sudah terpakai hapus buku.

import std/strutils

import db_connector/db_postgres

import kernel/ids

type
  ArrearsRow* = object
    ## Belum diparse: `Money` dibentuk pemanggil supaya satu tempat (composition root) yang
    ## memutuskan apa yang terjadi bila teks desimal rusak.
    loanId*: Id
    partyId*: Id
    branchId*: Id
    dueOn*: string ## jatuh tempo **tertua** yang masih bersisa; dasar DPD
    grade*: string ## golongan yang tercatat pada tanggal itu, `""` = belum dinilai
    principal*: string
    interest*: string
    penalty*: string

  AllowanceRow* = object
    grade*: string
    loans*: int64
    base*: string
    rateMicro*: int64
    allowance*: string

proc arrearsRows*(db: DbConn; asOf: string): seq[ArrearsRow] =
  ## Pinjaman `ACTIVE` yang punya angsuran lewat jatuh tempo dengan sisa > 0. Angsuran yang
  ## digantikan restrukturisasi tidak dihitung: kewajibannya sudah pindah ke jadwal baru.
  ##
  ## Golongan diambil dari snapshot **tanggal itu** bila ada; `""` bila task regrading belum
  ## berjalan — pemanggil memutuskan fallback-nya (DPD saat ini), bukan query ini.
  for row in db.getAllRows(sql"""
    SELECT l.loan_id::text, l.party_id::text, l.branch_id::text,
           min(i.due_on)::text,
           coalesce(max(s.grade), ''),
           sum(greatest(i.principal_due - i.paid_principal, 0))::numeric(24,2)::text,
           sum(greatest(i.interest_due - i.paid_interest, 0))::numeric(24,2)::text,
           sum(greatest(i.penalty_due - i.paid_penalty, 0))::numeric(24,2)::text
      FROM lending.loan l
      JOIN lending.installment i ON i.loan_id = l.loan_id
      LEFT JOIN lending.collectibility_snapshot s
        ON s.loan_id = l.loan_id AND s.business_date = ?::date
     WHERE l.status = 'ACTIVE'
       AND i.superseded_on IS NULL
       AND i.due_on < ?::date
       AND greatest(i.principal_due - i.paid_principal, 0)
         + greatest(i.interest_due - i.paid_interest, 0)
         + greatest(i.penalty_due - i.paid_penalty, 0) > 0
     GROUP BY l.loan_id, l.party_id, l.branch_id
     ORDER BY min(i.due_on), l.loan_id""", asOf, asOf):
    result.add ArrearsRow(
      loanId: Id(row[0]),
      partyId: Id(row[1]),
      branchId: Id(row[2]),
      dueOn: row[3],
      grade: row[4],
      principal: row[5],
      interest: row[6],
      penalty: row[7],
    )

proc allowanceRows*(db: DbConn; asOf: string): seq[AllowanceRow] =
  ## Penyisihan tercatat pada tanggal buku. `max(rate_micro)` dipakai supaya satu baris per
  ## golongan tetap bisa dibentuk walau tarif berubah di tengah hari; `mixedRates` di domain
  ## menandai keadaan itu alih-alih menyembunyikannya.
  for row in db.getAllRows(sql"""
    SELECT grade, count(*)::text,
           sum(base_amount)::numeric(24,2)::text,
           max(rate_micro)::text,
           sum(allowance)::numeric(24,2)::text
      FROM lending.ppap_snapshot
     WHERE business_date = ?::date
     GROUP BY grade
     ORDER BY grade""", asOf):
    result.add AllowanceRow(
      grade: row[0],
      loans: parseBiggestInt(row[1]),
      base: row[2],
      rateMicro: parseBiggestInt(row[3]),
      allowance: row[4],
    )

proc loanReceivableSubledger*(db: DbConn): string =
  ## Σ sisa pokok dari cache saldo. Pinjaman yang dihapusbukukan sudah dinolkan, jadi piutang yang
  ## tersisa hanya yang benar-benar masih ditagih.
  db.getValue(sql"""
    SELECT coalesce(sum(principal_outstanding), 0)::numeric(24,2)::text
      FROM lending.loan_balance""")

proc allowanceSubledger*(db: DbConn): string =
  ## Σ penyisihan **terakhir per pinjaman** (bukan Σ semua snapshot: setiap tanggal buku menyimpan
  ## saldo, bukan mutasi — menjumlahkan semuanya akan menghitung penyisihan berkali-kali).
  db.getValue(sql"""
    SELECT coalesce(sum(last.allowance), 0)::numeric(24,2)::text
      FROM (
        SELECT DISTINCT ON (loan_id) allowance
          FROM lending.ppap_snapshot
         ORDER BY loan_id, business_date DESC
      ) last""")

proc allowanceWrittenOff*(db: DbConn): string =
  db.getValue(sql"""
    SELECT coalesce(sum(allowance_applied), 0)::numeric(24,2)::text
      FROM lending.writeoff""")
