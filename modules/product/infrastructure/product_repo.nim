## Repositori `product` (T-076). SQL murni; invarian versi ditegakkan DB (EXCLUDE + trigger).

import std/[json, options, strutils]

import db_connector/db_postgres

import kernel/ids
import ../domain/product

const
  productColumns = "product_id, code, name, product_type, " &
    "to_char(created_at AT TIME ZONE 'UTC', 'YYYY-MM-DD\"T\"HH24:MI:SS\"Z\"')"

proc productOf(row: Row): Product =
  Product(productId: Id(row[0]), code: row[1], name: row[2],
    productType: parseProductType(row[3]), createdAt: row[4])

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
  let rows = db.getAllRows(sql"""
    SELECT version_id, product_id, version_no,
           to_char(effective_from, 'YYYY-MM-DD'), coalesce(to_char(effective_to, 'YYYY-MM-DD'), ''),
           to_char(published_at AT TIME ZONE 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS"Z"')
      FROM product.product_version
     WHERE product_id = ? AND effective_from <= ?::date
       AND (effective_to IS NULL OR effective_to >= ?::date)
     ORDER BY effective_from DESC LIMIT 1""", $productId, asOf, asOf)
  if rows.len == 0:
    return none(ProductVersion)
  some(ProductVersion(versionId: Id(rows[0][0]), productId: Id(rows[0][1]),
    versionNo: parseInt(rows[0][2]), effectiveFrom: rows[0][3], effectiveTo: rows[0][4],
    publishedAt: rows[0][5]))

proc openVersion*(db: DbConn, productId: Id): Option[ProductVersion] =
  ## Versi yang masih terbuka (`effective_to IS NULL`) — hanya boleh ada satu karena EXCLUDE.
  let rows = db.getAllRows(sql"""
    SELECT version_id, product_id, version_no,
           to_char(effective_from, 'YYYY-MM-DD'), coalesce(to_char(effective_to, 'YYYY-MM-DD'), ''),
           to_char(published_at AT TIME ZONE 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS"Z"')
      FROM product.product_version
     WHERE product_id = ? AND effective_to IS NULL
     ORDER BY effective_from DESC LIMIT 1""", $productId)
  if rows.len == 0:
    return none(ProductVersion)
  some(ProductVersion(versionId: Id(rows[0][0]), productId: Id(rows[0][1]),
    versionNo: parseInt(rows[0][2]), effectiveFrom: rows[0][3], effectiveTo: rows[0][4],
    publishedAt: rows[0][5]))

proc nextVersionNo*(db: DbConn, productId: Id): int =
  let raw = db.getValue(sql"""
    SELECT coalesce(max(version_no), 0)::text FROM product.product_version
     WHERE product_id = ?""", $productId)
  parseInt(raw) + 1

proc closeVersion*(db: DbConn, versionId: Id, newFrom: string): bool =
  ## Menutup **versi yang sudah dibaca** tepat sebelum versi baru mulai. `false` = versi itu sudah
  ## ditutup permintaan lain (balapan) — pemanggil memperlakukan sebagai konflik, bukan menutup
  ## versi lain yang belum divalidasi.
  db.getValue(sql"""
    UPDATE product.product_version
       SET effective_to = ?::date - 1
     WHERE version_id = ? AND effective_to IS NULL
     RETURNING version_id::text""", newFrom, $versionId).len > 0

proc insertVersion*(db: DbConn, v: ProductVersion, actor: Id) =
  db.exec(sql"""
    INSERT INTO product.product_version
      (version_id, product_id, version_no, effective_from, effective_to, published_by)
    VALUES (?, ?, ?, ?::date, NULLIF(?, '')::date, ?)""",
    $v.versionId, $v.productId, $v.versionNo, v.effectiveFrom, v.effectiveTo, $actor)

proc insertBinding*(db: DbConn, versionId: Id, binding: ParamBinding) =
  db.exec(sql"""
    INSERT INTO product.product_param_binding (version_id, param_key, value)
    VALUES (?, ?, ?::jsonb)""", $versionId, binding.paramKey, $binding.value)

proc versionsOf*(db: DbConn, productId: Id): seq[ProductVersion] =
  for row in db.getAllRows(sql"""
      SELECT version_id, product_id, version_no,
             to_char(effective_from, 'YYYY-MM-DD'),
             coalesce(to_char(effective_to, 'YYYY-MM-DD'), ''),
             to_char(published_at AT TIME ZONE 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS"Z"')
        FROM product.product_version
       WHERE product_id = ? ORDER BY version_no""", $productId):
    result.add ProductVersion(versionId: Id(row[0]), productId: Id(row[1]),
      versionNo: parseInt(row[2]), effectiveFrom: row[3], effectiveTo: row[4],
      publishedAt: row[5])

proc bindingsOf*(db: DbConn, versionId: Id): seq[ParamBinding] =
  for row in db.getAllRows(sql"""
      SELECT param_key, value::text
        FROM product.product_param_binding
       WHERE version_id = ? ORDER BY param_key""", $versionId):
    result.add ParamBinding(paramKey: row[0], value: parseJson(row[1]))
