## Scope yang sedang dilayani (spec §10.2) — dipakai bersama kalender, auth, dan (nanti) use case.
##
## Konvensi lookup: hanya scope pemanggil yang diberi id; tipe lain mengembalikan `""`
## (dianggap "tidak diminta") — konsekuensinya nilai level `INSTITUTION` dengan id konkret
## tidak terbaca dari konteks `BRANCH` (OPEN_ITEMS O-012).

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

proc lookupFor*(scope: ScopeRef): ScopeLookup =
  let scopeType = scope.scopeType
  let scopeId = scope.scopeId
  result = proc(t: ParamScopeType): string =
    if t == scopeType: scopeId else: ""

proc `$`*(s: ScopeRef): string =
  $s.scopeType & (if s.scopeId.len > 0: ":" & s.scopeId else: "")
