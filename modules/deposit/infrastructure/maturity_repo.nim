## Repositori perpindahan jatuh tempo deposito berjangka (T-138d). SQL murni: **tidak ada aturan
## bisnis** di sini — keputusan ARO ada di D-155 dan dijalankan composition root
## (`apps/api/src/daycloser_deposit.nim`).
##
## Bentuk yang dipegang:
##   - **halaman kandidat**: rekening berjangka yang sudah jatuh tempo pada tanggal buku, dengan
##     instruksi ARO, saldo pokok, dan akrual bunga terakhirnya ikut terbaca (satu kueri per chunk,
##     pola `interest_repo`).
##   - **pencarian rekening tujuan**: rekening tabungan aktif milik party yang sama di cabang yang
##     sama. Tidak ada = prasyarat operasional yang hilang (keputusan pemanggil, bukan repo).
##   - **mutasi**: tutup rekening, majukan `maturity_date`, dan sesuaikan saldo. Baris
##     `deposit.transaction` ditulis composition root lewat `transaction_repo.insertTransaction`
##     karena jumlah baris dan jurnalnya ditentukan keputusan ARO (D-155), bukan repo.
##
## **Paginasi memakai jendela di atas himpunan yang stabil.** Task ini mengubah `status` dan
## `maturity_date` — dua kolom yang dipakai penyaring "jatuh tempo". `LIMIT/OFFSET` langsung pada
## himpunan yang menyusut akan **melewati** rekening (baris yang sudah diproses hilang dari halaman
## berikutnya sehingga offset bergeser); akrual (T-138c) aman karena ia hanya menambah baris akrual,
## bukan mengubah populasi rekening. Karena itu nomor halaman dihitung di atas **seluruh** rekening
## `TIME_DEPOSIT` (`row_number()`), lalu penyaring jatuh tempo diterapkan sesudahnya: setiap rekening
## muncul tepat di satu halaman, dan halaman yang isinya kosong hanya berarti tidak ada yang jatuh
## tempo di jendela itu.

import std/[options, strutils]

import db_connector/db_postgres

import kernel/[ids, money, result]
import ../domain/account
import ./account_repo

type
  MaturityAccount* = object
    ## Satu rekening berjangka + data yang dibutuhkan keputusan ARO. `maturityDate`/`aroInstruction`
    ## kosong = kolom NULL di DB (rekening yang tidak pernah diisi jatuh tempo/instruksinya).
    account*: Account
    maturityDate*: string ## ISO `yyyy-MM-dd`; `""` = tanpa jatuh tempo (tidak pernah jatuh tempo)
    aroInstruction*: string ## `NONE`/`PRINCIPAL`/`PRINCIPAL_AND_INTEREST`; `""` = belum diatur
    accruedInterest*: Money ## `cumulative` akrual terakhir = bunga yang belum dibayar; nol bila none

proc countMaturityCandidates*(db: DbConn): int64 =
  ## Jumlah rekening yang **ikut dipaginasi**, bukan jumlah yang jatuh tempo: `countChunks` harus
  ## mencakup seluruh himpunan stabil, kalau tidak chunk terakhir tidak pernah dijalankan dan
  ## rekening yang jatuh tempo di dalamnya terlewat tanpa suara.
  int64(parseInt(db.getValue(sql"""
    SELECT count(*)::text FROM deposit.account WHERE account_type = 'TIME_DEPOSIT'""")))

proc dueMaturitiesPage*(db: DbConn; businessDate: string; offset, limit: int):
    seq[MaturityAccount] =
  ## Rekening berjangka yang jatuh tempo pada `businessDate` (`maturity_date <= tanggal buku`,
  ## status bukan `CLOSED`), diambil dari jendela `offset+1 .. offset+limit` himpunan stabil.
  ## Urut `account_id` supaya dua panggilan dengan jendela berbeda tidak tumpang tindih.
  let query = """
    WITH ranked AS (
      SELECT a.account_id, row_number() OVER (ORDER BY a.account_id) AS rn
        FROM deposit.account a
       WHERE a.account_type = 'TIME_DEPOSIT'
    )
    SELECT """ & accountColumns & """,
           coalesce(to_char(a.maturity_date, 'YYYY-MM-DD'), ''),
           coalesce(a.aro_instruction, ''),
           coalesce(latest.cumulative::text, '0.00')
      FROM deposit.account a
      JOIN ranked r ON r.account_id = a.account_id
      JOIN product.product p ON p.product_id = a.product_id
      LEFT JOIN deposit.account_balance b ON b.account_id = a.account_id
      LEFT JOIN LATERAL (
        SELECT ia.cumulative
          FROM deposit.interest_accrual ia
         WHERE ia.account_id = a.account_id
         ORDER BY ia.business_date DESC
         LIMIT 1
      ) latest ON true
     WHERE r.rn > ?::int AND r.rn <= ?::int
       AND a.status <> 'CLOSED'
       AND a.maturity_date <= ?::date
     ORDER BY a.account_id"""
  for row in db.getAllRows(sql(query), $offset, $(offset + limit), businessDate):
    let interest = moneyFromString(row[15])
    if interest.isErr:
      raise newException(ValueError, "bunga akrual rekening bukan desimal sah: " & row[15])
    result.add MaturityAccount(
      account: accountOf(row),
      maturityDate: row[13],
      aroInstruction: row[14],
      accruedInterest: interest.value())

proc activeSavingsAccount*(db: DbConn; partyId, branchId: Id): Option[Id] =
  ## Rekening tabungan `ACTIVE` milik party yang sama di cabang yang sama, urut nomor rekening.
  ## `ORDER BY account_no LIMIT 1` = rekening pertama yang dibuka; pemilihan rekening tujuan bukan
  ## keputusan repo, dan anggota dengan beberapa tabungan memakai yang paling awal dibuka.
  let rows = db.getAllRows(sql"""
    SELECT account_id FROM deposit.account
     WHERE account_type = 'SAVINGS' AND status = 'ACTIVE'
       AND party_id = ? AND branch_id = ?
     ORDER BY account_no
     LIMIT 1""", $partyId, $branchId)
  if rows.len == 0:
    return none(Id)
  some(Id(rows[0][0]))

proc closeAccount*(db: DbConn; accountId: Id; actor: Id) =
  ## Rekening berjangka selesai `NONE`: status `CLOSED` (saldo sudah dipindahkan pemanggil di
  ## transaksi yang sama).
  db.exec(sql"""
    UPDATE deposit.account SET status = 'CLOSED', updated_by = ?
     WHERE account_id = ?""", $actor, $accountId)

proc setMaturityDate*(db: DbConn; accountId: Id; maturityDate: string; actor: Id) =
  ## ARO `PRINCIPAL`/`PRINCIPAL_AND_INTEREST`: rekening berlanjut dengan jatuh tempo baru.
  db.exec(sql"""
    UPDATE deposit.account SET maturity_date = ?::date, updated_by = ?
     WHERE account_id = ?""", maturityDate, $actor, $accountId)

proc adjustBalance*(db: DbConn; accountId: Id; delta: Money): Option[Money] =
  ## Saldo cache `+ delta` (delta negatif = keluar). `none` = baris saldo tidak ada; saldo negatif
  ## ditolak CHECK `balance >= 0` di DB. Pemanggil yang memastikan besar perpindahannya.
  let rows = db.getAllRows(sql"""
      UPDATE deposit.account_balance
         SET balance = balance + ?::numeric, updated_at = now()
       WHERE account_id = ?
       RETURNING balance::text""", delta.toDecimalString, $accountId)
  if rows.len == 0:
    return none(Money)
  some(moneyFromString(rows[0][0]).value())
