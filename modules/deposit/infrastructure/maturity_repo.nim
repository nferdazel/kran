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
##
## **Keputusan tidak boleh memakai halaman apa adanya (O-112).** Halaman dibaca di luar transaksi
## chunk, jadi rekening di dalamnya bisa sudah berubah saat chunk berjalan: setoran tunai yang sudah
## lolos cek status bisa commit setelah rekening ditutup task ini (rekening `CLOSED` bersaldo, tanpa
## akrual lanjutan). Karena itu `lockMaturityAccount` mengunci baris rekening (`FOR UPDATE`) dan
## membaca ulang seluruh kolom keputusan sesudah kunci didapat. `lockAccountForUpdate` adalah kunci
## baris yang sama untuk jalur teller, supaya kedua jalur terserialisasi di satu baris.

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
    accruedInterest*: Money ## `cumulative` akrual terakhir (dihitung dari `opened_on`); nol bila none
    interestPaid*: Money ## bunga kumulatif yang sudah dibayar/dikapitalisasi pada siklus sebelumnya
    hasBalance*: bool ## `false` = baris `deposit.account_balance` tidak ada (cache hilang, bukan nol)

proc unpaidInterest*(item: MaturityAccount): Money =
  ## Bunga yang belum pernah dibayar = `cumulative − interest_paid_cumulative` (D-165). Siklus
  ## pertama: `paid = 0`, jadi seluruh akrual dibayar seperti sebelumnya. Siklus berikutnya hanya
  ## selisihnya, sehingga bunga siklus pertama tidak dibayar dua kali.
  item.accruedInterest - item.interestPaid

proc countMaturityCandidates*(db: DbConn): int64 =
  ## Jumlah rekening yang **ikut dipaginasi**, bukan jumlah yang jatuh tempo: `countChunks` harus
  ## mencakup seluruh himpunan stabil, kalau tidak chunk terakhir tidak pernah dijalankan dan
  ## rekening yang jatuh tempo di dalamnya terlewat tanpa suara.
  int64(parseInt(db.getValue(sql"""
    SELECT count(*)::text FROM deposit.account WHERE account_type = 'TIME_DEPOSIT'""")))

const
  ## Daftar kolom keputusan ARO: akun + kode produk + saldo (`accountColumns`), lalu jatuh tempo,
  ## instruksi ARO, `cumulative` akrual terakhir, dan keberadaan baris saldo. Satu sumber untuk
  ## halaman kandidat dan pembacaan terkunci supaya keduanya tidak bisa menyimpang.
  maturityColumns = accountColumns & """,
           coalesce(to_char(a.maturity_date, 'YYYY-MM-DD'), ''),
           coalesce(a.aro_instruction, ''),
           coalesce(latest.cumulative::text, '0.00'),
           b.account_id IS NOT NULL,
           coalesce(a.interest_paid_cumulative::text, '0.00')"""

  ## Sumber + join yang sama untuk kedua pembaca (produk, saldo, akrual terakhir).
  maturityFrom = """
      FROM deposit.account a
      JOIN product.product p ON p.product_id = a.product_id
      LEFT JOIN deposit.account_balance b ON b.account_id = a.account_id
      LEFT JOIN LATERAL (
        SELECT ia.cumulative
          FROM deposit.interest_accrual ia
         WHERE ia.account_id = a.account_id
         ORDER BY ia.business_date DESC
         LIMIT 1
      ) latest ON true"""

  ## Predikat "berhak diproses pada tanggal buku". Dipakai halaman kandidat **dan** pembacaan
  ## terkunci: rekening yang statusnya `CLOSED` atau jatuh temponya sudah dimajukan bukan lagi
  ## pekerjaan task ini.
  maturityPredicate = """a.status <> 'CLOSED' AND a.maturity_date <= ?::date"""

proc maturityAccountOf*(row: Row): MaturityAccount =
  ## Satu baris `maturityColumns` → `MaturityAccount`. Dipakai kedua pembaca; indeks kolom
  ## (13/14/15/16/17) mengikuti `accountColumns` yang berakhir di indeks 12.
  let interest = moneyFromString(row[15])
  if interest.isErr:
    raise newException(ValueError, "bunga akrual rekening bukan desimal sah: " & row[15])
  let paid = moneyFromString(row[17])
  if paid.isErr:
    raise newException(ValueError, "bunga yang sudah dibayar bukan desimal sah: " & row[17])
  MaturityAccount(
    account: accountOf(row),
    maturityDate: row[13],
    aroInstruction: row[14],
    accruedInterest: interest.value(),
    interestPaid: paid.value(),
    hasBalance: row[16] == "t")

proc dueMaturitiesPage*(db: DbConn; businessDate: string; offset, limit: int):
    seq[MaturityAccount] =
  ## Rekening berjangka yang jatuh tempo pada `businessDate` (`maturity_date <= tanggal buku`,
  ## status bukan `CLOSED`), diambil dari jendela `offset+1 .. offset+limit` himpunan stabil.
  ## Urut `account_id` supaya dua panggilan dengan jendela berbeda tidak tumpang tindih.
  ##
  ## Hasil halaman adalah **kandidat**, bukan keputusan: baris bisa berubah sebelum chunk berjalan
  ## (lihat `lockMaturityAccount`).
  let query = """
    WITH ranked AS (
      SELECT a.account_id, row_number() OVER (ORDER BY a.account_id) AS rn
        FROM deposit.account a
       WHERE a.account_type = 'TIME_DEPOSIT'
    )
    SELECT """ & maturityColumns & maturityFrom &
      """
      JOIN ranked r ON r.account_id = a.account_id
     WHERE r.rn > ?::int AND r.rn <= ?::int
       AND """ & maturityPredicate & """
     ORDER BY a.account_id"""
  for row in db.getAllRows(sql(query), $offset, $(offset + limit), businessDate):
    result.add maturityAccountOf(row)

proc lockMaturityAccount*(db: DbConn; accountId: Id; businessDate: string):
    Option[MaturityAccount] =
  ## Rekening jatuh tempo yang **terkunci**, dibaca ulang sesudah kuncinya didapat. `none` = rekening
  ## tidak lagi berhak diproses pada `businessDate` (sudah `CLOSED`, atau jatuh temponya sudah
  ## dimajukan proses lain); pemanggil wajib melewatinya tanpa memindahkan uang.
  ##
  ## Dua pernyataan, bukan satu `SELECT ... FOR UPDATE` berisi join: pernyataan baca kedua memakai
  ## snapshot baru (READ COMMITTED), sehingga saldo dan akrual yang berubah sebelum kunci didapat
  ## ikut terbaca, tanpa bergantung pada perilaku `EvalPlanQual` untuk baris hasil join.
  if db.getAllRows(sql("""
      SELECT a.account_id
        FROM deposit.account a
       WHERE a.account_id = ? AND """ & maturityPredicate & """
        FOR UPDATE OF a"""), $accountId, businessDate).len == 0:
    return none(MaturityAccount)
  let rows = db.getAllRows(sql("SELECT " & maturityColumns & maturityFrom &
    """
     WHERE a.account_id = ? AND """ & maturityPredicate), $accountId, businessDate)
  if rows.len == 0:
    return none(MaturityAccount)
  some(maturityAccountOf(rows[0]))

proc activeSavingsAccount*(db: DbConn; partyId, branchId: Id): Option[Id] =
  ## Rekening tabungan `ACTIVE` milik party yang sama di cabang yang sama, urut nomor rekening.
  ## `ORDER BY account_no LIMIT 1` = rekening pertama yang dibuka; pemilihan rekening tujuan bukan
  ## keputusan repo, dan anggota dengan beberapa tabungan memakai yang paling awal dibuka.
  ##
  ## **Rekening `DORMANT` boleh menjadi target.** Kredit jatuh tempo adalah aktivitas rekening, dan
  ## task `deposit.dormant` berjalan sesudah task ini sehingga pada penutupan yang sama rekening itu
  ## kembali `ACTIVE` (D-157 butir 3). Menolaknya akan membuat deposito anggota berakhir `DAY-343`
  ## hanya karena tabungannya lama tidak dipakai — dan reaktivasi tidak akan pernah terjadi.
  ##
  ## **Simpanan POKOK/WAJIB dikecualikan.** GL-nya ekuitas (`301.1`/`301.2`, `ledger/0014`),
  ## sedangkan perpindahan jatuh tempo mengkredit `201` (0065/0069); uang yang mendarat di sana akan
  ## salah klasifikasi **dan** tidak bisa ditarik (penarikan POKOK/WAJIB diblokir sejak T-111).
  ## Karena rekening POKOK biasanya yang pertama dibuka (`account_no` terkecil), tanpa penyaring ini
  ## ia justru menjadi target default.
  let rows = db.getAllRows(sql"""
    SELECT a.account_id
      FROM deposit.account a
      JOIN product.product p ON p.product_id = a.product_id
     WHERE a.account_type = 'SAVINGS' AND a.status IN ('ACTIVE', 'DORMANT')
       AND a.party_id = ? AND a.branch_id = ?
       AND coalesce(p.savings_kind, '') NOT IN ('POKOK', 'WAJIB')
     ORDER BY a.account_no
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
