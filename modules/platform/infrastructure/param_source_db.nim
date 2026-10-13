## Adaptor DB untuk port `ParamSource` + guard drift (T-016, spec §10.3, §10.4).
##
## Inilah satu-satunya tempat lapisan application "disambungkan" ke Postgres: port di
## `application/param_service.nim` tidak tahu apa pun soal driver (archcheck rule B).

import std/[options]

import db_connector/db_postgres

import ../application/[param_drift, param_service]
import ../domain/[param, scope]
import ./param_repo
import kernel/[paramkey, result]

proc dbParamSource*(db: DbConn): ParamSource =
  ## Sumber nilai aktif dari DB: definisi (schema/tipe) + nilai paling spesifik pada `asOf`.
  result.fetch = proc(key, asOf: string; scope: ScopeRef): Result[ParamSnapshot, ParamError] =
    let definition = definitionOf(db, key)
    if definition.isNone:
      return err[ParamSnapshot, ParamError](
        paramError(pekNotFound, key, "definisi parameter tidak ada di platform.param_definition"))
    let picked = resolveCandidate(candidatesOf(db, key, asOf), lookupFor(scope))
    if picked.isNone:
      return err[ParamSnapshot, ParamError](paramError(pekNotFound, key,
        "tidak ada nilai aktif pada " & asOf & " untuk scope " & $scope))
    ok[ParamSnapshot, ParamError](ParamSnapshot(value: picked.get().value,
      valueType: definition.get().valueType, schema: definition.get().schema))

proc dbDefinitions*(db: DbConn): seq[ParamDefinition] =
  ## Definisi parameter yang benar-benar terpasang di DB (untuk guard drift).
  for row in db.getAllRows(sql"""
    SELECT key, module, value_type, allowed_scopes, sensitivity, requires_approval,
           description_key, regulatory_refs
      FROM platform.param_definition ORDER BY key"""):
    var scopes: set[ParamScopeType]
    for s in pgArrayItems(row[3]):
      scopes.incl parseScopeType(s)
    result.add ParamDefinition(
      key: row[0],
      module: row[1],
      valueType: parseValueType(row[2]),
      scopes: scopes,
      sensitivity: parseSensitivity(row[4]),
      requiresApproval: row[5] == "t",
      descriptionKey: row[6],
      regulatoryRefs: pgArrayItems(row[7]))

proc driftAgainstDatabase*(db: DbConn;
                           codeDefs: openArray[ParamDefinition]): seq[DriftProblem] =
  ## Perbandingan definisi kode (hasil paramgen) vs DB.
  compareDefinitions(codeDefs, dbDefinitions(db))

proc watchParamChanges*(db: DbConn; service: ParamService; timeoutMs: int): seq[string] =
  ## Menunggu `NOTIFY platform_param_changed` lalu meng-invalidasi cache untuk key yang berubah.
  ##
  ## `LISTEN` harus sudah dipasang sekali per koneksi pendengar (`param_repo.listenChanges`) —
  ## di aplikasi nyata ini dipanggil saat startup, dan loop ini dijalankan oleh pemilik event
  ## loop (T-009 SSE hub), bukan thread terpisah.
  let keys = pollChanges(db, timeoutMs)
  for key in keys:
    if key.len > 0:
      discard service.invalidate(key)
  keys
