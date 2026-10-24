## Pemilik subledger sebuah jurnal (T-123): dipakai gerbang jurnal pembalik.
##
## **Kenapa cek ini ada.** Jurnal pembalik hanya memutar baris `ledger.journal_line`. Modul yang
## menyimpan keadaan sendiri di luar buku besar (saldo rekening, saldo vault, status sesi kas) tidak
## ikut berubah, sehingga pembalik akan membuat subledger dan GL berbeda tanpa jejak. Sampai modul
## itu punya jalur koreksi yang memutar keduanya, pembalik untuk jurnalnya **ditolak**.
##
## Deteksi bersifat **data**, bukan daftar nama event: yang menentukan adalah ada tidaknya baris
## subledger yang menunjuk jurnal itu (`deposit.transaction`, `deposit.transfer`,
## `teller.vault_topup_request`), atau jurnal sesi kas yang `source_ref`-nya `session_id`. Dengan
## begitu, event baru dari modul yang sama tetap tertangkap tanpa mendaftarkannya di sini.
##
## Query lintas schema sengaja tinggal di lapisan `apps/api` (perakit), bukan di modul `ledger`:
## ledger tidak boleh tahu tabel milik `deposit`/`teller` (AGENTS §1.1).

import db_connector/db_postgres

## Literal array Postgres, bukan `$seq` (yang menghasilkan `@[...]` dan gagal di-cast).
const sessionEventsSql = "{TellerSessionOpened,TellerSessionClosed,TellerCashOverage," &
  "TellerCashShortage}"

proc subledgerOwner*(db: DbConn, journalId: string): string =
  ## Nama tabel pemilik, atau `""` bila jurnal murni buku besar (boleh dibalik).
  let rows = db.getAllRows(sql"""
    SELECT 'deposit.transaction'
     WHERE EXISTS (SELECT 1 FROM deposit.transaction t WHERE t.journal_id = ?::uuid)
    UNION ALL
    SELECT 'deposit.transfer'
     WHERE EXISTS (SELECT 1 FROM deposit.transfer t WHERE t.journal_id = ?::uuid)
    UNION ALL
    SELECT 'teller.vault_topup_request'
     WHERE EXISTS (SELECT 1 FROM teller.vault_topup_request r WHERE r.journal_id = ?::uuid)
    UNION ALL
    SELECT 'teller.teller_session'
     WHERE EXISTS (
       SELECT 1 FROM teller.teller_session s
         JOIN ledger.journal j ON j.source_ref = s.session_id
        WHERE j.journal_id = ?::uuid AND j.source_event = ANY(?::text[]))
    LIMIT 1""", journalId, journalId, journalId, journalId, sessionEventsSql)
  if rows.len == 0: "" else: rows[0][0]
