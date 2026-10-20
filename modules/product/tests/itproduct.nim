## Integrasi DB modul `product` (T-076).
##
## Membuktikan invarian yang dijaga database, bukan hanya domain: versi wajib punya binding
## (deferred), versi tidak tumpang tindih, hanya `effective_to` yang boleh diisi sekali, dan binding
## immutable.

import std/[json, options, times, unittest]

import db_connector/db_postgres

import "platform-lib/db/config"
import "platform-lib/db/pool"
import dbtools/lib
import kernel/[clock, ids]
import product/domain/product
import product/infrastructure/product_repo

let envT = envTableFromProcess()
if not databaseUrlSet(envT):
  echo "itproduct: KRAN_DATABASE_URL kosong — dilewati"
  quit(0)

let dbPool = newDbPool(dbConfigFromEnv(envT))
let db = dbPool.acquire()

# Reset schema modul dulu (migrasi produk masih dalam pengembangan); jangan menerapkan migrasi
# yang checksum-nya berubah sebelum baris riwayatnya dibersihkan.
if db.getValue(sql"SELECT to_regclass('platform.schema_migration')::text").len > 0:
  db.exec(sql"DELETE FROM platform.schema_migration WHERE migration_id LIKE 'product/%'")
db.exec(sql"DROP SCHEMA IF EXISTS product CASCADE")
discard applyMigrations(db, ".")

let
  testClock = fakeClock(dateTime(2026, mOct, 20, 9, 0, 0))
  actor = Id("77777777-7777-7777-8777-777777777777")

proc newProduct(code = "SAV01", ptype = ptSavings): Product =
  Product(productId: newId(testClock), code: code, name: "Simpanan Sukarela",
    productType: ptype)

proc binding(key = "product.savings.min_balance", value = "0.0000"): ParamBinding =
  ParamBinding(paramKey: key, value: %value)

proc saveVersion(p: Product, versionNo: int, fromIso: string,
                 bindings: seq[ParamBinding] = @[binding()]): ProductVersion =
  let v = ProductVersion(versionId: newId(testClock), productId: p.productId,
    versionNo: versionNo, effectiveFrom: fromIso)
  discard dbPool.withTx(proc(d: DbConn): int {.closure.} =
    insertVersion(d, v, actor)
    for b in bindings:
      insertBinding(d, v.versionId, b)
    1)
  v

proc expectDbError(body: proc()) =
  var raised = false
  try:
    body()
  except DbError:
    raised = true
  check raised

var created: Product

suite "product: penyimpanan & versi":
  test "produk + versi + binding tersimpan dan terbaca":
    created = newProduct()
    discard dbPool.withTx(proc(d: DbConn): int {.closure.} =
      insertProduct(d, created, actor)
      1)
    discard saveVersion(created, 1, "2026-10-01",
      @[binding(), binding("product.savings.admin_fee", "5000.0000")])
    let stored = productByCode(db, "SAV01")
    check stored.isSome
    check stored.get().productType == ptSavings
    let versions = versionsOf(db, created.productId)
    check versions.len == 1
    check versions[0].versionNo == 1
    check versions[0].effectiveTo.len == 0
    check bindingsOf(db, versions[0].versionId).len == 2

  test "versi tanpa binding ditolak saat COMMIT (deferred)":
    let p = newProduct("SAV-NOBIND")
    discard dbPool.withTx(proc(d: DbConn): int {.closure.} =
      insertProduct(d, p, actor)
      1)
    let v = ProductVersion(versionId: newId(testClock), productId: p.productId,
      versionNo: 1, effectiveFrom: "2026-10-01")
    expectDbError(proc() =
      discard dbPool.withTx(proc(d: DbConn): int {.closure.} =
        insertVersion(d, v, actor)
        1))
    check versionsOf(db, p.productId).len == 0

  test "versi bertumpang tindih ditolak, versi bersambung diterima":
    # Versi 1 masih terbuka (sejak 1 Okt). Versi 2 mulai 1 Nov harus menutup versi 1 dulu.
    let v2 = ProductVersion(versionId: newId(testClock), productId: created.productId,
      versionNo: 2, effectiveFrom: "2026-11-01")
    expectDbError(proc() =
      discard dbPool.withTx(proc(d: DbConn): int {.closure.} =
        insertVersion(d, v2, actor)
        insertBinding(d, v2.versionId, binding())
        1))
    let openV1 = openVersion(db, created.productId).get()
    check closeVersion(db, openV1.versionId, "2026-11-01")
    check not closeVersion(db, openV1.versionId, "2026-11-01")
    discard saveVersion(created, 2, "2026-11-01",
      @[binding("product.savings.min_balance", "10000.0000")])
    check versionsOf(db, created.productId).len == 2
    check currentVersion(db, created.productId, "2026-10-31").get().versionNo == 1
    check currentVersion(db, created.productId, "2026-11-01").get().versionNo == 2
    check currentVersion(db, created.productId, "2026-11-01").get().effectiveTo.len == 0

  test "versi immutable: ubah effective_from/dihapus ditolak, effective_to hanya sekali":
    let versions = versionsOf(db, created.productId)
    let v1 = versions[0]
    expectDbError(proc() = db.exec(
      sql"UPDATE product.product_version SET effective_from = '2026-10-02' WHERE version_id = ?",
      $v1.versionId))
    expectDbError(proc() = db.exec(
      sql"DELETE FROM product.product_version WHERE version_id = ?", $v1.versionId))
    expectDbError(proc() = db.exec(
      sql"UPDATE product.product_version SET effective_to = '2026-12-01' WHERE version_id = ?",
      $v1.versionId))
    check versionsOf(db, created.productId)[0].effectiveTo == "2026-10-31"

  test "versi mulai besok (H+1) sah: versi lama menjadi satu hari":
    let p = newProduct("SAV-H1")
    discard dbPool.withTx(proc(d: DbConn): int {.closure.} =
      insertProduct(d, p, actor)
      1)
    let v1 = saveVersion(p, 1, "2026-10-01")
    check closeVersion(db, v1.versionId, "2026-10-02")
    discard saveVersion(p, 2, "2026-10-02")
    check versionsOf(db, p.productId)[0].effectiveTo == "2026-10-01"
    check currentVersion(db, p.productId, "2026-10-01").get().versionNo == 1
    check currentVersion(db, p.productId, "2026-10-02").get().versionNo == 2

  test "binding ke versi yang sudah terbit ditolak (sealed)":
    let sealedV1 = versionsOf(db, created.productId)[0]
    expectDbError(proc() = db.exec(
      sql"""INSERT INTO product.product_param_binding (version_id, param_key, value)
             VALUES (?, 'product.savings.grace_period_days', '0'::jsonb)""",
      $sealedV1.versionId))

  test "binding immutable":
    let v2 = versionsOf(db, created.productId)[1]
    expectDbError(proc() = db.exec(
      sql"UPDATE product.product_param_binding SET value = ?::jsonb WHERE version_id = ?",
      $ %*"1.0000", $v2.versionId))
    expectDbError(proc() = db.exec(
      sql"DELETE FROM product.product_param_binding WHERE version_id = ?", $v2.versionId))

  test "kode produk unik":
    let dup = newProduct("SAV01")
    expectDbError(proc() =
      discard dbPool.withTx(proc(d: DbConn): int {.closure.} =
        insertProduct(d, dup, actor)
        1))
