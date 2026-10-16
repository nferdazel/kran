## Scope yang sedang dilayani (spec §10.2) — dipakai bersama kalender, auth, dan (nanti) use case.
##
## Konvensi lookup: **hanya** tipe scope pemanggil yang "diminta", dan id-nya boleh kosong.
## `institutionScope()` karena itu mengembalikan `some("")` untuk INSTITUTION — bukan `none` —
## sehingga nilai level INSTITUTION dengan `scope_id` NULL (institusi akar) terjangkau (O-012).
## Tipe lain mengembalikan `none` dan tidak pernah cocok: tidak ada fallback diam-diam antar level.

import std/options

import ./param
import kernel/paramkey

type
  ScopeRef* = object
    scopeType*: ParamScopeType
    scopeId*: string ## "" = akar (institusi tanpa id / global)

proc institutionScope*(): ScopeRef =
  ScopeRef(scopeType: pstInstitution, scopeId: "")

proc branchScope*(branchId: string): ScopeRef =
  ScopeRef(scopeType: pstBranch, scopeId: branchId)

proc lookupFor*(scope: ScopeRef): ScopeValueLookup =
  let scopeType = scope.scopeType
  let scopeId = scope.scopeId
  result = proc(t: ParamScopeType): Option[string] =
    if t == scopeType: some(scopeId) else: none(string)

proc `$`*(s: ScopeRef): string =
  $s.scopeType & (if s.scopeId.len > 0: ":" & s.scopeId else: "")
