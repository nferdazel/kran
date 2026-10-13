## Tipe domain modul `platform`: catatan audit (spec §9.1(7), §18.2).
##
## Murni: tanpa I/O. Hash rantai **tidak** dihitung di sini — rantai adalah properti tabel
## (`platform.audit_log` + trigger), bukan aturan yang bisa dilanggar pemanggil.

import std/json
import kernel/[ids, auditcontext, clock]

type
  AuditEntry* = object
    auditId*: Id
    ctx*: AuditContext
    action*: string       ## mis. `param.update`, `user.unmask`
    resourceType*: string ## mis. `param_value`, `user`
    resourceId*: string   ## id/kunci entitas (string bebas)
    role*: string
    businessDate*: string ## `YYYY-MM-DD` atau "" (diisi use case dari BusinessDate)
    before*: JsonNode     ## snapshot sebelum (nil), tanpa PII mentah
    after*: JsonNode      ## snapshot sesudah (nil)

proc newAuditEntry*(
    ctx: AuditContext,
    action, resourceType, resourceId: string,
    clock: Clock,
    role = "",
    businessDate = "",
    before: JsonNode = nil,
    after: JsonNode = nil,
): AuditEntry =
  AuditEntry(
    auditId: newId(clock),
    ctx: ctx,
    action: action,
    resourceType: resourceType,
    resourceId: resourceId,
    role: role,
    businessDate: businessDate,
    before: before,
    after: after,
  )

proc primaryBranch*(e: AuditEntry): Id =
  ## Cabang yang dicatat (audit menyimpan satu cabang; daftar lengkap ada di konteks sesi).
  if e.ctx.branchIds.len > 0: e.ctx.branchIds[0] else: Id("")
