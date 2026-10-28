## Rekonsiliasi cache saldo rekening simpanan terhadap baris sumbernya (T-101).
##
## `deposit.account_balance` adalah **cache**; sumber kebenaran mutasi rekening ada di
## `deposit.transaction` (tunai T-088b + perpindahan jatuh tempo T-138d) dan `deposit.transfer`
## (pemindahbukuan, T-088c/D-124).
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
WITH typed AS (
  SELECT t.account_id, t.amount,
         CASE t.tx_type
           WHEN 'CASH_DEPOSIT' THEN 1
           WHEN 'CASH_WITHDRAWAL' THEN -1
           WHEN 'MATURITY_OUT' THEN -1
           WHEN 'MATURITY_IN' THEN 1
           WHEN 'INTEREST_CREDIT' THEN 1
         END AS sign
    FROM deposit.transaction t
), cash AS (
  SELECT account_id, sum(sign * amount) AS net
    FROM typed
   GROUP BY account_id
), unmapped AS (
  -- Jenis baris yang tidak dikenal **tidak** boleh diam-diam dihitung sebagai keluar: sum()
  -- melewati NULL, jadi tanpa penanda ini saldo yang direkonstruksi akan kurang tanpa suara.
  SELECT DISTINCT account_id FROM typed WHERE sign IS NULL
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
         CASE WHEN u.account_id IS NULL
              THEN coalesce(c.net, 0) + coalesce(i.net, 0) - coalesce(o.net, 0)
              ELSE NULL
         END AS balance
    FROM deposit.account a
    LEFT JOIN cash c ON c.account_id = a.account_id
    LEFT JOIN unmapped u ON u.account_id = a.account_id
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
  ## Rekening yang cache saldonya tidak sama dengan mutasi tunai + perpindahan jatuh tempo + PB.
  ## `branchId` kosong = semua.
  ##
  ## Tanda mengikuti jenis baris: `CASH_DEPOSIT`/`MATURITY_IN`/`INTEREST_CREDIT` menambah saldo,
  ## `CASH_WITHDRAWAL`/`MATURITY_OUT` mengurangi (D-155: jatuh tempo tidak memindahkan kas, jadi
  ## dulu `CASH_*` tidak bisa dipakai). Baris dengan jenis yang tidak dikenal membuat `expected`
  ## kosong (`NULL`) — sengaja gagal-terang, bukan selisih palsu yang diam.
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

type
  SubledgerTotal* = object
    ## Total saldo subledger simpanan untuk dibandingkan dengan GL (gate pasca-tutup, spec §11.5).
    ## `missingCache` > 0 berarti ada rekening tanpa baris saldo — totalnya tidak bisa dipercaya.
    accounts*: int64
    missingCache*: int64
    total*: string ## desimal `numeric(24,2)`

proc subledgerTotal*(db: DbConn): SubledgerTotal =
  let row = db.getAllRows(sql"""
    SELECT count(a.account_id)::text,
           count(*) FILTER (WHERE b.balance IS NULL)::text,
           coalesce(sum(b.balance), 0)::numeric(24, 2)::text
      FROM deposit.account a
      LEFT JOIN deposit.account_balance b ON b.account_id = a.account_id""")
  if row.len > 0:
    result.accounts = parseBiggestInt(row[0][0]).int64
    result.missingCache = parseBiggestInt(row[0][1]).int64
    result.total = row[0][2]
