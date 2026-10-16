## Test integrasi enkripsi field-level (T-054): membuktikan mekanisme bisa dipakai end-to-end
## pada tabel **sementara** (TEMP TABLE) — enkripsi → simpan → cari lewat blind index → dekripsi.
##
## Butuh `KRAN_DATABASE_URL` (lihat docs/runbooks/dev-db.md); tanpa itu, dilewati.
## Tidak ada kolom PII nyata yang dienkripsi: tabel dibuat sementara di dalam test ini.

import std/[base64, os, strutils, tables, unittest]
import db_connector/db_postgres

import "platform-lib/crypto/fieldcrypto"
import "platform-lib/db/config"
import "platform-lib/db/pool"

let envT = envTableFromProcess()
if not databaseUrlSet(envT):
  echo "itfieldcrypto: KRAN_DATABASE_URL kosong — dilewati"
  quit(0)

let dbPool = newDbPool(dbConfigFromEnv(envT))

const kekB64 = "AAECAwQFBgcICQoLDA0ODxAREhMUFRYXGBkaGxwdHh8="

let tmpRoot = getTempDir() / ("kran-it-fieldcrypto-" & $getCurrentProcessId())
createDir(tmpRoot)
let kekPath = tmpRoot / "kek.key"
writeFile(kekPath, "v1:" & kekB64 & "\n")
when not defined(windows):
  setFilePermissions(kekPath, {fpUserRead, fpUserWrite})

let fc = fieldCryptoFromEnv(toTable({envVarKekFile: kekPath}))

type
  Row = object
    nik: string
    decrypted: string
    stored: string

suite "fieldcrypto e2e (tabel sementara)":
  test "enkripsi → simpan → cari lewat blind index → dekripsi":
    let rows = dbPool.withConn(proc(db: DbConn): seq[Row] =
      db.exec(sql"""
        CREATE TEMP TABLE anggota (
          id int primary key, nik_enc text not null, nik_bidx text not null)""")
      let niks = ["3172010101900001", "3273010101900002", "3172010101900003"]
      for i, nik in niks:
        let bidx = blindIndex(fc, "anggota", normalizeDigits(nik))
        let c = encryptField(fc, "anggota", nik)
        db.exec(sql"INSERT INTO anggota (id, nik_enc, nik_bidx) VALUES (?, ?, ?)",
          i + 1, c, bidx)
      for nik in niks:
        let bidx = blindIndex(fc, "anggota", normalizeDigits(nik))
        let stored = db.getValue(sql"SELECT nik_enc FROM anggota WHERE nik_bidx = ?", bidx)
        result.add Row(nik: nik, decrypted: decryptField(fc, "anggota", stored),
          stored: stored)
    )
    check rows.len == 3
    for r in rows:
      check r.decrypted == r.nik
      # yang tersimpan di DB adalah ciphertext, bukan NIK apa adanya
      check not r.stored.contains(r.nik)
      check r.stored.startsWith(ciphertextPrefix & ":")

  test "pencarian nilai yang tidak ada → nol baris (bukan false positive)":
    let hits = dbPool.withConn(proc(db: DbConn): int =
      db.exec(sql"""
        CREATE TEMP TABLE anggota2 (
          id int primary key, nik_enc text not null, nik_bidx text not null)""")
      db.exec(sql"INSERT INTO anggota2 (id, nik_enc, nik_bidx) VALUES (?, ?, ?)",
        1, encryptField(fc, "anggota", "3172010101900001"),
        blindIndex(fc, "anggota", "3172010101900001"))
      db.getAllRows(sql"SELECT id FROM anggota2 WHERE nik_bidx = ?",
        blindIndex(fc, "anggota", "9999999999999999")).len
    )
    check hits == 0

  test "ciphertext yang diubah di DB → gagal dekripsi, bukan output sampah":
    let ok = dbPool.withConn(proc(db: DbConn): bool =
      db.exec(sql"""
        CREATE TEMP TABLE anggota3 (
          id int primary key, nik_enc text not null, nik_bidx text not null)""")
      let c = encryptField(fc, "anggota", "3172010101900001")
      db.exec(sql"INSERT INTO anggota3 (id, nik_enc, nik_bidx) VALUES (?, ?, ?)",
        1, c, blindIndex(fc, "anggota", "3172010101900001"))
      let stored = db.getValue(sql"SELECT nik_enc FROM anggota3 WHERE id = 1")
      var parts = stored.split(':')
      var blob = base64.decode(parts[5])
      blob[0] = chr(ord(blob[0]) xor 1)
      parts[5] = base64.encode(blob, safe = true).strip(chars = {'='})
      db.exec(sql"UPDATE anggota3 SET nik_enc = ? WHERE id = 1", parts.join(":"))
      let rusak = db.getValue(sql"SELECT nik_enc FROM anggota3 WHERE id = 1")
      try:
        discard decryptField(fc, "anggota", rusak)
        false
      except DecryptError:
        true
    )
    check ok

dbPool.close()
removeDir(tmpRoot)
