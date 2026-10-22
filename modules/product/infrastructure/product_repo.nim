## Repositori `product` (T-076). SQL murni; invarian versi ditegakkan DB (EXCLUDE + trigger).

import std/[json, options, strutils]

import db_connector/db_postgres

import kernel/ids
import ../domain/product

const
  productColumns = "product_id, code, name, product_type, " &
    "to_char(created_at AT TIME ZONE 'UTC', 'YYYY-MM-DD\"T\"HH24:MI:SS\"Z\"')"
  versionColumns = "version_id, product_id, version_no, " &
    "to_char(effective_from, 'YYYY-MM-DD'), " &
    "coalesce(to_char(effective_to, 'YYYY-MM-DD'), ''), status, maker, " &
    "to_char(published_at AT TIME ZONE 'UTC', 'YYYY-MM-DD\"T\"HH24:MI:SS\"Z\"'), " &
    "coalesce(to_char(approved_at AT TIME ZONE 'UTC', 'YYYY-MM-DD\"T\"HH24:MI:SS\"Z\"'), ''), " &
    "coalesce(reject_reason, '')"

proc productOf(row: Row): Product =
  Product(productId: Id(row[0]), code: row[1], name: row[2],
    productType: parseProductType(row[3]), createdAt: row[4])

proc versionOf(row: Row): ProductVersion =
  ProductVersion(versionId: Id(row[0]), productId: Id(row[1]),
    versionNo: parseInt(row[2]), effectiveFrom: row[3], effectiveTo: row[4],
    status: parseVersionStatus(row[5]), maker: Id(row[6]), publishedAt: row[7],
    approvedAt: row[8], rejectReason: row[9])

proc insertProduct*(db: DbConn, p: Product, actor: Id) =
  db.exec(sql"""
    INSERT INTO product.product (product_id, code, name, product_type, created_by, updated_by)
    VALUES (?, ?, ?, ?, ?, ?)""",
    $p.productId, p.code, p.name, $p.productType, $actor, $actor)

proc productByCode*(db: DbConn, code: string): Option[Product] =
  let rows = db.getAllRows(
    sql("SELECT " & productColumns & " FROM product.product WHERE code = ?"), code)
  if rows.len == 0:
    return none(Product)
  some(productOf(rows[0]))

proc productById*(db: DbConn, productId: Id): Option[Product] =
  let rows = db.getAllRows(
    sql("SELECT " & productColumns & " FROM product.product WHERE product_id = ?"), $productId)
  if rows.len == 0:
    return none(Product)
  some(productOf(rows[0]))

proc listProducts*(db: DbConn, asOf: string): seq[Product] =
  ## Daftar produk (header). Versi yang berlaku diambil terpisah oleh `currentVersion` karena
  ## SQL-nya lebih jelas dipisah daripada satu join lateral yang bercabang.
  for row in db.getAllRows(
    sql("SELECT " & productColumns & " FROM product.product ORDER BY code")):
    result.add productOf(row)

proc currentVersion*(db: DbConn, productId: Id, asOf: string): Option[ProductVersion] =
  ## Versi yang berlaku pada `asOf`. Hanya versi `ACTIVE` yang terlihat katalog (D-119): draft yang
  ## belum disetujui tidak boleh bocor.
  let rows = db.getAllRows(sql("SELECT " & versionColumns &
      """
      FROM product.product_version
     WHERE product_id = ? AND status = 'ACTIVE' AND effective_from <= ?::date
       AND (effective_to IS NULL OR effective_to >= ?::date)
     ORDER BY effective_from DESC LIMIT 1"""), $productId, asOf, asOf)
  if rows.len == 0:
    return none(ProductVersion)
  some(versionOf(rows[0]))

proc openVersion*(db: DbConn, productId: Id): Option[ProductVersion] =
  ## Versi `ACTIVE` yang masih terbuka (`effective_to IS NULL`) — hanya boleh ada satu karena
  ## EXCLUDE parsial. Versi `DRAFT` sengaja tidak dianggap "berjalan" (D-119).
  let rows = db.getAllRows(sql("SELECT " & versionColumns &
      """
      FROM product.product_version
     WHERE product_id = ? AND status = 'ACTIVE' AND effective_to IS NULL
     ORDER BY effective_from DESC LIMIT 1"""), $productId)
  if rows.len == 0:
    return none(ProductVersion)
  some(versionOf(rows[0]))

proc versionById*(db: DbConn, versionId: Id): Option[ProductVersion] =
  let rows = db.getAllRows(sql("SELECT " & versionColumns &
    " FROM product.product_version WHERE version_id = ?"), $versionId)
  if rows.len == 0:
    return none(ProductVersion)
  some(versionOf(rows[0]))

proc nextVersionNo*(db: DbConn, productId: Id): int =
  let raw = db.getValue(sql"""
    SELECT coalesce(max(version_no), 0)::text FROM product.product_version
     WHERE product_id = ?""", $productId)
  parseInt(raw) + 1

proc closeVersion*(db: DbConn, versionId: Id, newFrom: string): bool =
  ## Menutup **versi ACTIVE yang sudah dibaca** tepat sebelum versi baru mulai. `false` = versi itu
  ## sudah ditutup permintaan lain (balapan) — pemanggil memperlakukan sebagai konflik, bukan menutup
  ## versi lain yang belum divalidasi.
  db.getValue(sql"""
    UPDATE product.product_version
       SET effective_to = ?::date - 1
     WHERE version_id = ? AND status = 'ACTIVE' AND effective_to IS NULL
     RETURNING version_id::text""", newFrom, $versionId).len > 0

proc insertVersion*(db: DbConn, v: ProductVersion, actor: Id) =
  ## Versi baru selalu lahir `DRAFT` (D-119); maker = pengaju. Trigger `fill_version_maker` hanya
  ## jaring rolling deploy untuk binary lama, jadi kolomnya diisi eksplisit di sini.
  db.exec(sql"""
    INSERT INTO product.product_version
      (version_id, product_id, version_no, effective_from, effective_to, published_by, status, maker)
    VALUES (?, ?, ?, ?::date, NULLIF(?, '')::date, ?, 'DRAFT', ?)""",
    $v.versionId, $v.productId, $v.versionNo, v.effectiveFrom, v.effectiveTo, $actor, $actor)

proc approveVersion*(db: DbConn, versionId: Id, checker: Id): bool =
  ## DRAFT → ACTIVE oleh checker: seal + `approved_at`. `false` = baris bukan DRAFT lagi (balapan
  ## dua checker). `checker = maker` ditolak CHECK DB (`product_version_self_approval_chk`).
  db.getValue(sql"""
    UPDATE product.product_version
       SET status = 'ACTIVE', checker = ?, approved_at = now(), sealed = true
     WHERE version_id = ? AND status = 'DRAFT'
     RETURNING version_id::text""", $checker, $versionId).len > 0

proc rejectVersion*(db: DbConn, versionId: Id, checker: Id, reason: string): bool =
  ## DRAFT → REJECTED oleh checker: seal + alasan; draft tidak dihapus (D-119).
  db.getValue(sql"""
    UPDATE product.product_version
       SET status = 'REJECTED', checker = ?, reject_reason = ?, sealed = true
     WHERE version_id = ? AND status = 'DRAFT'
     RETURNING version_id::text""", $checker, reason, $versionId).len > 0

proc insertBinding*(db: DbConn, versionId: Id, binding: ParamBinding) =
  db.exec(sql"""
    INSERT INTO product.product_param_binding (version_id, param_key, value)
    VALUES (?, ?, ?::jsonb)""", $versionId, binding.paramKey, $binding.value)

proc versionsOf*(db: DbConn, productId: Id): seq[ProductVersion] =
  for row in db.getAllRows(sql("SELECT " & versionColumns &
      """
        FROM product.product_version
       WHERE product_id = ? ORDER BY version_no"""), $productId):
    result.add versionOf(row)

proc bindingsOf*(db: DbConn, versionId: Id): seq[ParamBinding] =
  for row in db.getAllRows(sql"""
      SELECT param_key, value::text
        FROM product.product_param_binding
       WHERE version_id = ? ORDER BY param_key""", $versionId):
    result.add ParamBinding(paramKey: row[0], value: parseJson(row[1]))
