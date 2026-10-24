## Rekonsiliasi cache saldo rekening simpanan terhadap baris sumbernya (T-101).
##
## `deposit.account_balance` adalah **cache**; sumber kebenaran mutasi rekening ada di
## `deposit.transaction` (tunai, T-088b) dan `deposit.transfer` (pemindahbukuan, T-088c/D-124).
## Rekonsiliasi **tidak** memakai jurnal per rekening: jurnal PB sengaja net-nol di akun `201`
## (kedua kaki akun GL yang sama), jadi saldo per rekening tidak bisa direkonstruksi dari
## `journal_line` saja (lihat `docs/ACCEPTED-LIMITS.md`).
##
## Baca saja. Tidak ada penulisan koreksi di sini: selisih adalah temuan yang harus diselidiki
## (day-close Fase 3 akan menjadwalkan pemeriksaan ini dan menandai selisih).

import std/strutils

import db_connector/db_postgres

type
  BalanceMismatch* = object
    accountNo*: string
    branchId*: string
    cached*: string ## `""` bila baris `account_balance` tidak ada (rekening tanpa cache)
    expected*: string
    delta*: string  ## cache − seharusnya

const reconciliationSql = """
WITH cash AS (
  SELECT t.account_id,
         sum(CASE WHEN t.tx_type = 'CASH_DEPOSIT' THEN t.amount ELSE -t.amount END) AS net
    FROM deposit.transaction t
   GROUP BY t.account_id
), incoming AS (
  SELECT tr.destination_account_id AS account_id, sum(tr.amount) AS net
    FROM deposit.transfer tr
   GROUP BY tr.destination_account_id
), outgoing AS (
  SELECT tr.source_account_id AS account_id, sum(tr.amount) AS net
    FROM deposit.transfer tr
   GROUP BY tr.source_account_id
), expected AS (
  SELECT a.account_id,
         coalesce(c.net, 0) + coalesce(i.net, 0) - coalesce(o.net, 0) AS balance
    FROM deposit.account a
    LEFT JOIN cash c ON c.account_id = a.account_id
    LEFT JOIN incoming i ON i.account_id = a.account_id
    LEFT JOIN outgoing o ON o.account_id = a.account_id
   WHERE (? = '' OR a.branch_id::text = ?)
)
SELECT a.account_no, a.branch_id::text, coalesce(b.balance::text, ''),
       e.balance::numeric(24,2)::text,
       (coalesce(b.balance, 0) - e.balance)::numeric(24,2)::text
  FROM expected e
  JOIN deposit.account a ON a.account_id = e.account_id
  LEFT JOIN deposit.account_balance b ON b.account_id = e.account_id
 WHERE b.balance IS DISTINCT FROM e.balance
 ORDER BY a.account_no"""

proc accountBalanceMismatches*(db: DbConn, branchId = ""): seq[BalanceMismatch] =
  ## Rekening yang cache saldonya tidak sama dengan mutasi tunai + PB. `branchId` kosong = semua.
  ##
  ## Rekening tanpa baris `account_balance` ikut dilaporkan (`cached == ""`): cache yang hilang
  ## bukan "tidak ada masalah", melainkan keadaan yang membuat saldo tidak bisa dibaca.
  for row in db.getAllRows(sql(reconciliationSql), branchId, branchId):
    result.add BalanceMismatch(
      accountNo: row[0],
      branchId: row[1],
      cached: row[2],
      expected: row[3],
      delta: row[4],
    )

proc reconciledAccountCount*(db: DbConn, branchId = ""): int64 =
  ## Jumlah rekening yang ikut diperiksa, untuk ringkasan keluaran.
  let raw = db.getValue(sql"""
    SELECT count(*)::text FROM deposit.account a
     WHERE (? = '' OR a.branch_id::text = ?)""", branchId, branchId)
  if raw.len == 0: 0'i64 else: parseBiggestInt(raw).int64
