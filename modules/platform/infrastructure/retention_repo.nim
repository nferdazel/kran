## Retensi outbox/inbox (T-282, D-206, spec §5.6): ambang dari parameter + dua perintah hapus.
##
## Satu berkas, bukan dua, karena yang dipakai task day-close adalah **pasangan** "baca ambang,
## lalu hapus" — memisahkannya membuat tiap pemanggil menyusun ulang pasangan itu dan gampang
## lupa membaca ambangnya sama sekali.
##
## Yang dihapus hanya riwayat, bukan bukti: outbox `DONE`/`DEAD` yang sudah lewat masa retensi
## (masih bisa di-*re-drive* selama masa itu), dan inbox yang hanya penanda de-dup. Bukti transaksi
## tetap ledger — karena itu hard delete di sini tidak menghilangkan apa pun yang diaudit.
##
## Tidak ada nilai bawaan di sini: 30 hari adalah keputusan (D-206), datang dari parameter
## `platform.outbox.retention_days` / `platform.inbox.retention_days`.

import std/json

import db_connector/db_postgres

import ../domain/scope
import ./param_repo

proc retentionDays*(db: DbConn, key, asOf: string): int =
  ## Ambang retensi (hari) yang berlaku pada `asOf`, pada scope INSTITUTION.
  ##
  ## Raise `ValueError` bila parameter tidak punya nilai aktif atau nilainya bukan bilangan >= 1.
  ## Pemanggil **wajib** memperlakukan itu sebagai kegagalan, bukan sebagai "lewati saja": nilai
  ## yang tidak terbaca tidak boleh diterjemahkan menjadi interval yang lebih pendek dari
  ## kebijakan, dan tidak boleh juga menjadi "hapus semua".
  let value = activeValueJson(db, key, asOf, lookupFor(institutionScope()))
  if value.kind != JInt or value.getInt < 1:
    raise newException(ValueError, "parameter " & key &
      " harus bilangan hari >= 1, bukan " & $value)
  int(value.getInt)

proc purgeOutbox*(db: DbConn, days, batch: int): int =
  ## Menghapus satu batch baris `DONE`/`DEAD` yang `completed_at`-nya lebih tua dari `days`.
  ## Mengembalikan jumlah baris terhapus; pemanggil mengulang sampai hasilnya kurang dari `batch`,
  ## supaya tabel besar tidak ditahan satu transaksi panjang.
  ##
  ## Jamnya dari `completed_at` (transisi terakhir ke `DONE`/`DEAD`), bukan `occurred_at`: baris
  ## yang lahir lama tapi baru mati kemarin masih bukti pengiriman dan masih bisa di-re-drive.
  ## Predikat status dipertahankan walau `completed_at` sudah terisi, supaya baris yang di-re-drive
  ## (kembali `PENDING`) tidak ikut terhapus sebelum selesai lagi.
  db.execAffectedRows(sql"""
      WITH doomed AS (
        SELECT outbox_id
          FROM platform.outbox
         WHERE status IN ('DONE', 'DEAD')
           AND completed_at < now() - make_interval(days => ?::int)
         ORDER BY completed_at
         LIMIT ?)
      DELETE FROM platform.outbox o
       USING doomed d
       WHERE o.outbox_id = d.outbox_id""", $days, batch)

proc purgeInbox*(db: DbConn, days, batch: int): int =
  ## Menghapus satu batch baris inbox yang `received_at`-nya lebih tua dari `days`.
  ##
  ## Aman dihapus karena baris inbox hanya penanda "peristiwa ini sudah pernah diproses konsumen
  ## itu". Event yang sama datang lagi setelah barisnya hilang akan diproses ulang — kontrak
  ## at-least-once, dan konsumennya idempoten. `ctid` dipakai sebagai kunci hapus supaya
  ## `LIMIT` tetap terpenuhi walau tabel tidak punya primary key tunggal.
  db.execAffectedRows(sql"""
      WITH doomed AS (
        SELECT ctid
          FROM platform.inbox
         WHERE received_at < now() - make_interval(days => ?::int)
         ORDER BY received_at
         LIMIT ?)
      DELETE FROM platform.inbox i
       USING doomed d
       WHERE i.ctid = d.ctid""", $days, batch)
