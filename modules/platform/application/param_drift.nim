## Guard drift: definisi parameter di **kode** vs di **DB** (spec §10.4 "drift guard").
##
## Murni: pemanggil memberi dua daftar definisi (`kernel.ParamDefinition`) — kode hasil
## `tools/paramgen` dan isi tabel `platform.param_definition` — lalu fungsi ini melaporkan
## perbedaannya. Dipakai saat startup dan di CI (uji integrasi).

import std/[algorithm, sequtils, sets, strutils]

import kernel/paramkey

type
  DriftKind* = enum
    dkMissingInDb = "MISSING_IN_DB"     ## ada di kode, belum diterapkan ke DB
    dkMissingInCode = "MISSING_IN_CODE" ## ada di DB, tidak ada di kode (key yatim)
    dkTypeMismatch = "TYPE_MISMATCH"
    dkModuleMismatch = "MODULE_MISMATCH"
    dkScopeMismatch = "SCOPE_MISMATCH"
    dkSensitivityMismatch = "SENSITIVITY_MISMATCH"
    dkApprovalMismatch = "APPROVAL_MISMATCH"

  DriftProblem* = object
    kind*: DriftKind
    key*: string
    detail*: string

proc `$`*(p: DriftProblem): string =
  $p.kind & " " & p.key & ": " & p.detail

proc scopesCsv*(scopes: set[ParamScopeType]): string =
  var parts: seq[string]
  for s in scopes:
    parts.add $s
  parts.sort()
  parts.join(",")

proc compareDefinitions*(codeDefs, dbDefs: openArray[ParamDefinition]): seq[DriftProblem] =
  ## Membandingkan per key. Urutan hasil deterministik (diurutkan per key, lalu jenis).
  var byKey: seq[(string, int)]
  for d in codeDefs:
    byKey.add (d.key, 0)
  for d in dbDefs:
    byKey.add (d.key, 1)
  byKey.sort()
  var keys: seq[string]
  for (k, _) in byKey:
    if keys.len == 0 or keys[^1] != k:
      keys.add k

  for key in keys:
    var inCode: seq[ParamDefinition]
    var inDb: seq[ParamDefinition]
    for d in codeDefs:
      if d.key == key:
        inCode.add d
    for d in dbDefs:
      if d.key == key:
        inDb.add d
    if inCode.len > 0 and inDb.len == 0:
      result.add DriftProblem(kind: dkMissingInDb, key: key,
        detail: "dideklarasikan di seeds/params.yaml tetapi belum ada di platform.param_definition")
      continue
    if inDb.len > 0 and inCode.len == 0:
      result.add DriftProblem(kind: dkMissingInCode, key: key,
        detail: "ada di DB tetapi tidak ada di definisi kode (key yatim)")
      continue
    if inCode.len > 1 or inDb.len > 1:
      result.add DriftProblem(kind: dkMissingInCode, key: key,
        detail: "definisi ganda (kode " & $inCode.len & ", DB " & $inDb.len & ")")
      continue
    let (c, d) = (inCode[0], inDb[0])
    if c.valueType != d.valueType:
      result.add DriftProblem(kind: dkTypeMismatch, key: key,
        detail: valueTypeName(c.valueType) & " (kode) vs " & valueTypeName(d.valueType) & " (DB)")
    if c.module != d.module:
      result.add DriftProblem(kind: dkModuleMismatch, key: key,
        detail: c.module & " (kode) vs " & d.module & " (DB)")
    if scopesCsv(c.scopes) != scopesCsv(d.scopes):
      result.add DriftProblem(kind: dkScopeMismatch, key: key,
        detail: scopesCsv(c.scopes) & " (kode) vs " & scopesCsv(d.scopes) & " (DB)")
    if c.sensitivity != d.sensitivity:
      result.add DriftProblem(kind: dkSensitivityMismatch, key: key,
        detail: sensitivityName(c.sensitivity) & " (kode) vs " & sensitivityName(d.sensitivity) &
          " (DB)")
    if c.requiresApproval != d.requiresApproval:
      result.add DriftProblem(kind: dkApprovalMismatch, key: key,
        detail: $c.requiresApproval & " (kode) vs " & $d.requiresApproval & " (DB)")

proc driftKeys*(problems: openArray[DriftProblem]): seq[string] =
  ## Ringkas: daftar key yang bermasalah (untuk pesan gagal-cepat saat startup).
  let s = toHashSet(problems.mapIt(it.key))
  for k in s:
    result.add k
  result.sort()
