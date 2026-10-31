## Repositori akrual bunga deposito (T-138c). SQL murni: tidak ada aturan bisnis di sini.
##
## Bentuk yang dipegang:
##   - **halaman akun**: rekening berjangka yang masih diakrualkan, urut `account_id`, dengan nilai
##     binding versi produk (rate/basis/skala) dan akrual terakhirnya ikut terbaca. Satu kueri per
##     chunk, bukan satu kueri per rekening: 1.000 rekening × 4 kueri bukan biaya yang perlu dibayar
##     setiap malam.
##   - **sisip**: `ON CONFLICT DO NOTHING` atas PK `(account_id, business_date)`. `false` berarti
##     baris sudah ada — pemanggil memperlakukannya sebagai pelanggaran (dijalankan di bawah advisory
##     lock, jadi seharusnya tidak pernah terjadi) dan membatalkan transaksi, bukan diam-diam
##     melewati akrual yang belum dijurnal.
##
## Tidak ada `UPDATE` saldo di sini: akrual menambah kewajiban (`204`) dan beban (`501`) lewat
## jurnal, bukan mengubah saldo rekening. Saldo baru berubah saat bunga diposting (T-138d).

import std/[json, strutils]

import db_connector/db_postgres

import kernel/ids
import ../domain/account
import ./account_repo

const
  ## Binding versi produk yang dibutuhkan akrual (spec §10.5, D-137). Kuncinya bukan nilai
  ## bisnis — nilainya tetap milik produk; yang tetap adalah **nama** atribut yang dibaca kode.
  rateParamKey = "product.savings.interest_rate"
  basisParamKey = "product.savings.day_count_basis"
  scaleParamKey = "product.savings.rounding_scale"

type
  AccrualAccount* = object
    ## Satu rekening + syarat akrualnya. Nilai binding dibiarkan `JsonNode` (validasi bentuk milik
    ## pemanggil, sama seperti `min_balance` di handler teller); `nil` = binding tidak ada.
    account*: Account
    rateValue*: JsonNode
    basisValue*: JsonNode
    scaleValue*: JsonNode
    lastDate*: string ## `""` = belum pernah diakrualkan
    lastCumulative*: string ## teks desimal; `"0.00"` bila belum pernah
    maturityDate*: string ## `""` = tanpa jatuh tempo (rekening tabungan)

proc countAccrualAccounts*(db: DbConn): int64 =
  ## Jumlah rekening yang akan diakrualkan. `status <> 'CLOSED'` (bukan daftar nilai) supaya
  ## `DORMANT` (`0071`) otomatis ikut tanpa mengubah task, sesuai keputusan pemilik: dormant
  ## membatasi transaksi, bukan perjanjian bunga (D-154 butir 1, D-157).
  int64(parseInt(db.getValue(sql"""
    SELECT count(*)::text FROM deposit.account
     WHERE account_type = 'TIME_DEPOSIT' AND status <> 'CLOSED'""")))

proc accrualAccountsPage*(db: DbConn; offset, limit: int): seq[AccrualAccount] =
  ## Halaman rekening akrual, urut `account_id`. Paginasi offset dipakai karena data akun tidak
  ## berubah selama run (advisory lock mencegah run kedua, dan akrual tidak menambah rekening).
  for row in db.getAllRows(sql("SELECT " & accountColumns &
      """,
             latest.business_date::text, coalesce(latest.cumulative::text, '0.00'),
             rate.value::text, basis.value::text, scale.value::text,
             coalesce(to_char(a.maturity_date, 'YYYY-MM-DD'), '')
        FROM deposit.account a
        JOIN product.product p ON p.product_id = a.product_id
        LEFT JOIN deposit.account_balance b ON b.account_id = a.account_id
        LEFT JOIN LATERAL (
          SELECT ia.business_date, ia.cumulative
            FROM deposit.interest_accrual ia
           WHERE ia.account_id = a.account_id
           ORDER BY ia.business_date DESC
           LIMIT 1
        ) latest ON true
        LEFT JOIN product.product_param_binding rate
               ON rate.version_id = a.product_version_id AND rate.param_key =
                  'product.savings.interest_rate'
        LEFT JOIN product.product_param_binding basis
               ON basis.version_id = a.product_version_id AND basis.param_key =
                  'product.savings.day_count_basis'
        LEFT JOIN product.product_param_binding scale
               ON scale.version_id = a.product_version_id AND scale.param_key =
                  'product.savings.rounding_scale'
       WHERE a.account_type = 'TIME_DEPOSIT' AND a.status <> 'CLOSED'
       ORDER BY a.account_id
       LIMIT ?::int OFFSET ?::int"""), $limit, $offset):
    result.add AccrualAccount(
      account: accountOf(row),
      lastDate: row[13],
      lastCumulative: row[14],
      rateValue: (if row[15].len == 0: nil else: parseJson(row[15])),
      basisValue: (if row[16].len == 0: nil else: parseJson(row[16])),
      scaleValue: (if row[17].len == 0: nil else: parseJson(row[17])),
      maturityDate: row[18])

proc insertAccrual*(db: DbConn; accountId: Id; businessDate, principal, ratePercent,
                    amount, cumulative: string; days, basisDays: int;
                    journalId: Id): bool =
  ## `false` = baris untuk `(account, tanggal)` sudah ada. `principal`/`amount`/`cumulative` dalam
  ## teks desimal kanonik `Money` (tanpa float, spec §9.1(2)); `journalId` kosong = tidak ada jurnal
  ## (bunga nol atau belum dijurnal).
  db.getValue(sql"""
    INSERT INTO deposit.interest_accrual
      (account_id, business_date, principal, days, rate_percent, basis_days, amount, cumulative,
       journal_id)
    VALUES (?, ?::date, ?::numeric, ?, ?::numeric, ?, ?::numeric, ?::numeric,
            NULLIF(?, '')::uuid)
    ON CONFLICT (account_id, business_date) DO NOTHING
    RETURNING account_id::text""",
    $accountId, businessDate, principal, days, ratePercent, basisDays, amount, cumulative,
    $journalId).len > 0

