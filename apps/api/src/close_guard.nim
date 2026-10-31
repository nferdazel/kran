## Gerbang transaksi saat business date `CLOSING` (spec §11.5 #3, `daycloser.txn_policy_during_close`).
##
## Ditaruh di pembungkus permintaan (`server.requestHandler`), bukan di tiap handler: kebijakan ini
## berlaku untuk **semua** perubahan lewat HTTP, dan penjagaan per handler akan bolong setiap kali
## endpoint baru ditambahkan. Pengecualiannya sempit dan disengaja: rute autentikasi tetap hidup
## supaya operator bisa masuk untuk melihat/menangani penutupan.
##
## Bukan pengganti otorisasi: permintaan yang ditolak di sini belum tentu sah untuk pemanggilnya.
## Urutannya sengaja "tutup dulu, izin kemudian" — saat buku sedang ditutup, tidak ada perubahan
## yang boleh menyelinap lewat jalur mana pun.

import std/[json, options, strutils]

import db_connector/db_postgres

import "platform-lib/db/pool"
import "platform-lib/log"

import kernel/paramkey
import kernel/generated/paramkeys

import platform/domain/[calendar, scope]
import platform/infrastructure/[calendar_repo, param_repo]

import daycloser/domain/[state, types]

type
  CloseGuardVerdict* = enum
    cgAllow
    cgBlock

const
  ## Rute yang tetap boleh menulis saat `CLOSING`.
  ##
  ## `auth/`: tanpa masuk/keluar, ganti kata sandi, dan MFA, penutupan yang macet juga mengunci
  ## operator dari sistem yang seharusnya ia tangani.
  ##
  ## `dayclose/`: aksi resume/pause/cancel **hanya** berguna saat `CLOSING`; menolaknya di sini
  ## berarti satu-satunya jalan keluar dari penutupan macet ada di server. Pengecualian ini tidak
  ## melemahkan otorisasi — aksi tetap menuntut sesi, izin `dayclose.run.manage`, dan grant tanpa
  ## batas cabang.
  ##
  ## Semua awalan memakai garis miring penutup supaya `/api/v1/authorization/...` atau
  ## `/api/v1/daycloser/...` tidak ikut terbuka hanya karena berawalan sama. Daftar ini **satu
  ## definisi** dengan `exemptWritePrefixes` di `tools/openapi/lib.nim` (dikunci test `topenapi`).
  closeGuardExemptPrefixes* = ["/api/v1/auth/", "/api/v1/dayclose/"]

proc closeGuardApplies*(httpMethod, path: string): bool =
  ## Murni: apakah permintaan ini termasuk yang dijaga. `GET/HEAD/OPTIONS` tidak pernah mengubah
  ## apa pun, jadi tidak perlu melihat basis data.
  if httpMethod notin ["POST", "PUT", "PATCH", "DELETE"]:
    return false
  for prefix in closeGuardExemptPrefixes:
    if path.startsWith(prefix):
      return false
  true

proc txnPolicy(db: DbConn; asOf: string): TxnPolicyDuringClose =
  ## Kebijakan aktif institusi. Nilai hilang/rusak **menolak** transaksi: penutupan yang sedang
  ## berjalan tidak boleh dilonggarkan oleh parameter yang belum tersemai.
  let raw = db.activeValueJson(keyString(P_daycloser_txn_policy_during_close), asOf,
    lookupFor(institutionScope()))
  if raw.kind != JString:
    raise newException(ValueError, "kebijakan transaksi bukan string: " & $raw)
  parseTxnPolicy(raw.getStr)

proc closeGuardVerdict*(pool: DbPool; asOf: string): CloseGuardVerdict {.gcsafe.} =
  ## Menjawab "apakah perubahan HTTP harus ditolak sekarang?".
  ##
  ## Gagal membaca basis data = **izinkan**: permintaan yang bersangkutan akan gagal sendiri saat
  ## menyentuh DB (503), dan menyamarkan gangguan basis data sebagai "buku sedang ditutup" akan
  ## menyesatkan operator. Yang tidak boleh terjadi adalah sebaliknya — meloloskan perubahan
  ## karena tidak bisa memastikan keadaan penutupan.
  if pool.isNil:
    return cgAllow
  {.cast(gcsafe).}:
    try:
      result = pool.withConn(proc(db: DbConn): CloseGuardVerdict {.gcsafe.} =
        {.cast(gcsafe).}:
          let bd = businessDateOf(db, institutionScope())
          if bd.isNone or bd.get.state != bdsClosing:
            cgAllow
          else:
            try:
              if txnPolicy(db, asOf) == tpcAllow:
                cgAllow
              else:
                cgBlock
            except ValueError as e:
              # Parameter hilang/tidak sah: fail-closed, dan berisik di log supaya segera
              # diperbaiki.
              discard newLogger().error("kebijakan transaksi saat CLOSING tidak terbaca",
                [("detail", e.msg)])
              cgBlock)
    except IOError as e:
      discard newLogger().warn("gerbang penutupan tidak dapat memeriksa basis data",
        [("detail", e.msg)])
      result = cgAllow
