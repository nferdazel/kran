## Integrasi DB modul `product` (T-076 + T-086).
##
## Membuktikan invarian yang dijaga database, bukan hanya domain: versi lahir DRAFT, approve/reject
## men-seal dan tidak bisa dibalik, hanya versi ACTIVE yang boleh bertumpang tindih (EXCLUDE parsial),
## self-approval ditolak CHECK, `approved_at`/`reject_reason` hanya sekali, binding immutable, dan
## binding hanya boleh masuk selama versi masih DRAFT.

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
discard applyAllMigrations(db, ".")

let
  testClock = fakeClock(dateTime(2026, mOct, 20, 9, 0, 0))
  actor = Id("77777777-7777-7777-8777-777777777777")
  checker = Id("88888888-8888-7888-8888-888888888888")

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

proc insertProduct(p: Product) =
  discard dbPool.withTx(proc(d: DbConn): int {.closure.} =
    insertProduct(d, p, actor)
    1)

proc expectDbError(body: proc()) =
  var raised = false
  try:
    body()
  except DbError:
    raised = true
  check raised

var created: Product

suite "product: penyimpanan & status versi":
  test "produk + versi lahir DRAFT; draft tidak bocor ke katalog":
    created = newProduct()
    insertProduct(created)
    let v1 = saveVersion(created, 1, "2026-10-01",
      @[binding(), binding("product.savings.admin_fee", "5000.0000")])
    let stored = productByCode(db, "SAV01")
    check stored.isSome
    check stored.get().productType == ptSavings
    let versions = versionsOf(db, created.productId)
    check versions.len == 1
    check versions[0].versionNo == 1
    check versions[0].status == vsDraft
    check versions[0].maker == actor
    check versions[0].approvedAt.len == 0
    check versions[0].effectiveTo.len == 0
    check bindingsOf(db, versions[0].versionId).len == 2
    # DRAFT belum terbit: katalog/openVersion mengabaikannya.
    check currentVersion(db, created.productId, "2026-10-01").isNone
    check openVersion(db, created.productId).isNone
    check versionById(db, v1.versionId).get().status == vsDraft

  test "versi tanpa binding boleh DRAFT, tetapi approve ditolak":
    let p = newProduct("SAV-NOBIND")
    insertProduct(p)
    let v = ProductVersion(versionId: newId(testClock), productId: p.productId,
      versionNo: 1, effectiveFrom: "2026-10-01")
    discard dbPool.withTx(proc(d: DbConn): int {.closure.} =
      insertVersion(d, v, actor)
      1)
    check versionsOf(db, p.productId).len == 1
    expectDbError(proc() = discard approveVersion(db, v.versionId, checker))
    check versionById(db, v.versionId).get().status == vsDraft

  test "approve men-seal DRAFT dan menerbitkannya ke katalog; approve kedua gagal":
    let v1 = versionsOf(db, created.productId)[0]
    check approveVersion(db, v1.versionId, checker)
    let approved = versionById(db, v1.versionId).get()
    check approved.status == vsActive
    check approved.approvedAt.len > 0
    check openVersion(db, created.productId).get().versionNo == 1
    check currentVersion(db, created.productId, "2026-10-01").get().versionNo == 1
    # Sudah ACTIVE: approve lagi bukan transisi yang sah.
    check not approveVersion(db, v1.versionId, checker)
    check not rejectVersion(db, v1.versionId, checker, "terlambat")

  test "self-approval ditolak CHECK (checker = maker)":
    let p = newProduct("SAV-SELF")
    insertProduct(p)
    let v = saveVersion(p, 1, "2026-10-01")
    # maker = actor; menyetujui dengan actor sendiri ditolak constraint/domain.
    expectDbError(proc() = discard approveVersion(db, v.versionId, actor))
    check versionById(db, v.versionId).get().status == vsDraft

  test "reject menyimpan alasan + seal; versi tidak dihapus":
    let p = newProduct("SAV-REJ")
    insertProduct(p)
    let v = saveVersion(p, 1, "2026-10-01")
    check rejectVersion(db, v.versionId, checker, "atribut tidak sesuai kebijakan")
    let rejected = versionById(db, v.versionId).get()
    check rejected.status == vsRejected
    check rejected.rejectReason == "atribut tidak sesuai kebijakan"
    check rejected.approvedAt.len == 0
    check openVersion(db, p.productId).isNone
    # REJECTED bukan DRAFT lagi: approve maupun reject ulang gagal.
    check not approveVersion(db, v.versionId, checker)
    check not rejectVersion(db, v.versionId, checker, "ulang")

suite "product: tumpang tindih & penutupan versi":
  test "dua draft tumpang tindih sah; approve menutup versi ACTIVE sebelumnya":
    let p = newProduct("SAV-DRAFT")
    insertProduct(p)
    let v1 = saveVersion(p, 1, "2026-10-01")
    let v2 = saveVersion(p, 2, "2026-11-01")
    let v3 = saveVersion(p, 3, "2026-10-15", @[binding("product.savings.min_balance", "7.0000")])
    # Ketiganya DRAFT dan boleh bertumpang tindih (EXCLUDE hanya berlaku untuk ACTIVE).
    check versionsOf(db, p.productId).len == 3
    check openVersion(db, p.productId).isNone

    check approveVersion(db, v1.versionId, checker)
    # Handler menutup versi ACTIVE sebelumnya sebelum approve; di level repo itu langkah terpisah.
    check closeVersion(db, v1.versionId, v2.effectiveFrom)
    check approveVersion(db, v2.versionId, checker)
    # Approve v2 menutup v1 sehari sebelum tanggal mulai.
    check versionById(db, v1.versionId).get().effectiveTo == "2026-10-31"
    check currentVersion(db, p.productId, "2026-10-31").get().versionNo == 1
    check currentVersion(db, p.productId, "2026-11-01").get().versionNo == 2

    # v3 bertabrakan dengan v1/v2 yang sudah ACTIVE → EXCLUDE menolak.
    expectDbError(proc() = discard approveVersion(db, v3.versionId, checker))
    check versionById(db, v3.versionId).get().status == vsDraft

  test "versi immutable: ubah effective_from/dihapus ditolak, effective_to hanya sekali":
    let versions = versionsOf(db, created.productId)
    let v1 = versions[0]
    expectDbError(proc() = db.exec(
      sql"UPDATE product.product_version SET effective_from = '2026-10-02' WHERE version_id = ?",
      $v1.versionId))
    expectDbError(proc() = db.exec(
      sql"DELETE FROM product.product_version WHERE version_id = ?", $v1.versionId))
    # created v1 masih terbuka (ACTIVE); effective_to bisa diisi sekali, kedua kali ditolak.
    check closeVersion(db, v1.versionId, "2026-11-01")
    expectDbError(proc() = db.exec(
      sql"UPDATE product.product_version SET effective_to = '2026-12-01' WHERE version_id = ?",
      $v1.versionId))
    check versionsOf(db, created.productId)[0].effectiveTo == "2026-10-31"

  test "binding ke versi yang sudah ACTIVE ditolak":
    let activeV1 = versionsOf(db, created.productId)[0]
    expectDbError(proc() = db.exec(
      sql"""INSERT INTO product.product_param_binding (version_id, param_key, value)
             VALUES (?, 'product.savings.grace_period_days', '0'::jsonb)""",
      $activeV1.versionId))

  test "INSERT langsung non-DRAFT atau maker palsu ditolak trigger":
    let p = productByCode(db, "SAV-DRAFT").get()
    # Seed/import SQL tidak boleh melewati jalur approve: ACTIVE tanpa binding tidak akan pernah
    # bisa diberi binding karena binding hanya untuk DRAFT.
    expectDbError(proc() = db.exec(sql"""
      INSERT INTO product.product_version
        (version_id, product_id, version_no, effective_from, published_by, status)
      VALUES (gen_random_uuid(), ?, 99, '2027-01-01', ?, 'ACTIVE')""",
      $p.productId, $actor))
    expectDbError(proc() = db.exec(sql"""
      INSERT INTO product.product_version
        (version_id, product_id, version_no, effective_from, published_by, maker)
      VALUES (gen_random_uuid(), ?, 98, '2027-02-01', ?, ?)""",
      $p.productId, $actor, $checker))

  test "binding immutable":
    let p = productByCode(db, "SAV-DRAFT").get()
    let v2 = versionsOf(db, p.productId)[1]
    expectDbError(proc() = db.exec(
      sql"UPDATE product.product_param_binding SET value = ?::jsonb WHERE version_id = ?",
      $ %*"1.0000", $v2.versionId))
    expectDbError(proc() = db.exec(
      sql"DELETE FROM product.product_param_binding WHERE version_id = ?", $v2.versionId))

  test "kode produk unik":
    let dup = newProduct("SAV01")
    expectDbError(proc() = insertProduct(dup))
