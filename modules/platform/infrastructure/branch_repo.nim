## Repositori master cabang (D-135): kode 3 digit + nama. SQL murni, tanpa aturan bisnis.
##
## Pemakaian pertama: pembukaan rekening butuh `code` untuk prefiks nomor rekening
## (`formatAccountNo`), dan `ctl create-branch` mendaftarkan cabang baru. Modul lain tetap
## menyimpan `branch_id` tanpa FK (expand-only, lihat migrasi `0030`).

import std/[options, strutils]

import db_connector/db_postgres

import kernel/ids

type
  Branch* = object
    branchId*: Id
    code*: string
    name*: string
    status*: string

  BranchRow* = Branch

const branchColumns = "branch_id, code, name, status"

proc validBranchCode*(code: string): bool =
  ## Kode cabang = tepat 3 digit, sama dengan CHECK `platform_branch_code_fmt`. Salinan kecil dari
  ## pemeriksaan di `deposit/domain/account.nim` disengaja: modul tidak boleh saling mengimpor
  ## domain, dan masing-masing pihak butuh jawaban sebelum menulis.
  if code.len != 3:
    return false
  for ch in code:
    if ch notin {'0' .. '9'}:
      return false
  true

proc branchOf(row: Row): Branch =
  Branch(
    branchId: Id(row[0]),
    code: row[1],
    name: row[2],
    status: row[3],
  )

proc branchById*(db: DbConn, branchId: Id): Option[Branch] =
  ## `getRow` mengembalikan Row berisi kolom kosong bila hasilnya nol baris (jebakan
  ## db_connector), jadi "tidak ditemukan" dideteksi lewat `getAllRows`.
  let rows = db.getAllRows(sql("SELECT " & branchColumns &
      " FROM platform.branch WHERE branch_id = ?"),
    $branchId)
  if rows.len == 0:
    return none(Branch)
  some(branchOf(rows[0]))

proc branchByCode*(db: DbConn, code: string): Option[Branch] =
  let rows = db.getAllRows(sql("SELECT " & branchColumns & " FROM platform.branch WHERE code = ?"),
    code)
  if rows.len == 0:
    return none(Branch)
  some(branchOf(rows[0]))

proc insertBranch*(db: DbConn, branchId: Id, code, name: string): bool =
  ## Mendaftarkan cabang baru. `false` bila kode sudah dipakai cabang lain (UNIQUE) — pemanggil
  ## yang memutuskan kode keluar/pesan, bukan repo.
  let rows = db.getAllRows(sql"""
    INSERT INTO platform.branch (branch_id, code, name)
    VALUES (?, ?, ?)
    ON CONFLICT (code) DO NOTHING
    RETURNING branch_id""", $branchId, code, name.strip)
  rows.len > 0

proc listBranches*(db: DbConn): seq[Branch] =
  for row in db.getAllRows(sql("SELECT " & branchColumns & " FROM platform.branch ORDER BY code")):
    result.add branchOf(row)
