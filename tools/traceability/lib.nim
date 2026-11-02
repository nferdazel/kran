## Traceability gate (spec §4.4, O-027) — register regulasi ↔ kontrol ↔ test.
##
## Register dibaca dari `docs/compliance/register.yaml`. Untuk setiap requirement `active`:
##   - wajib punya minimal satu kontrol (parameter atau modul), dan
##   - wajib punya minimal satu test yang **benar-benar ada**: berkasnya ada dan memuat
##     `test "<nama>"` persis.
##
## Kenapa nama test ikut dicocokkan: berkas test bisa tetap ada sementara test-nya dihapus atau
## di-rename, dan gate yang hanya memeriksa nama berkas akan hijau tanpa bukti.

import std/[json, os, sets, strutils]
import yaml/tojson

type
  TraceProblem* = object
    requirement*: string
    message*: string

  TestRef* = object
    file*: string
    name*: string

  Requirement* = object
    id*: string
    title*: string
    status*: string
    params*: seq[string]
    modules*: seq[string]
    tests*: seq[TestRef]

  Register* = object
    requirements*: seq[Requirement]
    problems*: seq[TraceProblem]

proc fail(problems: var seq[TraceProblem]; requirement, message: string) =
  problems.add TraceProblem(requirement: requirement, message: message)

proc strList(node: JsonNode; what: string; requirement: string;
    problems: var seq[TraceProblem]; required = false): seq[string] =
  if node.isNil or node.kind == JNull:
    if required:
      fail(problems, requirement, what & " wajib diisi")
    return @[]
  if node.kind != JArray:
    fail(problems, requirement, what & " harus berupa daftar")
    return @[]
  for item in node.items:
    if item.kind != JString or item.getStr().len == 0:
      fail(problems, requirement, what & " hanya boleh berisi teks tidak kosong")
      continue
    result.add item.getStr()

proc loadRegister*(path: string): Register =
  if not fileExists(path):
    raise newException(IOError, "register tidak ditemukan: " & path)
  let nodes = loadToJson(readFile(path))
  if nodes.len == 0 or nodes[0].kind != JObject:
    raise newException(ValueError, path & ": harus berupa mapping dengan kunci `requirements`")
  let doc = nodes[0]
  if not doc.hasKey("requirements") or doc["requirements"].kind != JArray:
    raise newException(ValueError, path & ": `requirements` harus berupa daftar")
  var seen = initHashSet[string]()
  for entry in doc["requirements"].items:
    if entry.kind != JObject:
      fail(result.problems, "?", "setiap requirement harus berupa mapping")
      continue
    let id = if entry.hasKey("id"): entry["id"].getStr("") else: ""
    if id.len == 0:
      fail(result.problems, "?", "requirement tanpa `id`")
      continue
    if id in seen:
      fail(result.problems, id, "id duplikat")
    seen.incl id
    let status = if entry.hasKey("status"): entry["status"].getStr("") else: ""
    if status notin ["active", "deferred"]:
      fail(result.problems, id, "`status` harus `active` atau `deferred`, dapat: " & status)
    var req = Requirement(
      id: id,
      title: if entry.hasKey("title"): entry["title"].getStr("") else: "",
      status: status,
    )
    if entry.hasKey("controls"):
      let controls = entry["controls"]
      if controls.kind != JObject:
        fail(result.problems, id, "`controls` harus berupa mapping")
      else:
        req.params = strList(if controls.hasKey("params"): controls["params"] else: nil,
          "controls.params", id, result.problems)
        req.modules = strList(if controls.hasKey("modules"): controls["modules"] else: nil,
          "controls.modules", id, result.problems)
    if entry.hasKey("tests"):
      if entry["tests"].kind != JArray:
        fail(result.problems, id, "`tests` harus berupa daftar")
      else:
        for t in entry["tests"].items:
          if t.kind != JObject or not t.hasKey("file") or not t.hasKey("name"):
            fail(result.problems, id, "setiap test harus punya `file` dan `name`")
            continue
          req.tests.add TestRef(file: t["file"].getStr(""), name: t["name"].getStr(""))
    result.requirements.add req

proc paramKeysOf*(root: string): HashSet[string] =
  ## Kunci parameter yang benar-benar ada di `modules/*/seeds/params.yaml`. Dibaca dari sumber
  ## definisinya, bukan dari generated SQL, supaya gate tidak bergantung pada `paramgen-gen` yang
  ## mungkin belum dijalankan.
  result = initHashSet[string]()
  let modulesDir = root / "modules"
  if not dirExists(modulesDir):
    return
  for kind, path in walkDir(modulesDir):
    if kind != pcDir:
      continue
    let seeds = path / "seeds" / "params.yaml"
    if not fileExists(seeds):
      continue
    let nodes = loadToJson(readFile(seeds))
    if nodes.len == 0 or nodes[0].kind != JArray:
      continue
    for entry in nodes[0].items:
      if entry.kind == JObject and entry.hasKey("key"):
        result.incl entry["key"].getStr("")

proc containsTest(filePath, name: string): bool =
  let needle = "test \"" & name & "\""
  readFile(filePath).contains(needle)

proc validate*(root: string; register: Register): seq[TraceProblem] =
  let paramKeys = paramKeysOf(root)
  for req in register.requirements:
    if req.status != "active":
      continue
    # Kontrol: minimal satu parameter atau modul. Requirement aktif tanpa kontrol berarti tidak
    # ada apa pun di sistem yang menjaganya.
    if req.params.len == 0 and req.modules.len == 0:
      fail(result, req.id, "requirement aktif tanpa kontrol (params/modules)")
    for key in req.params:
      if key notin paramKeys:
        fail(result, req.id, "parameter tidak ada di seeds/params.yaml: " & key)
    for moduleName in req.modules:
      if not dirExists(root / "modules" / moduleName):
        fail(result, req.id, "modul tidak ada: modules/" & moduleName)
    if req.tests.len == 0:
      fail(result, req.id, "requirement aktif tanpa test")
    for t in req.tests:
      let path = root / t.file
      if not fileExists(path):
        fail(result, req.id, "berkas test tidak ada: " & t.file)
      elif t.name.len == 0:
        fail(result, req.id, "test tanpa nama di " & t.file)
      elif not containsTest(path, t.name):
        fail(result, req.id, "test tidak ditemukan di " & t.file & ": \"" & t.name & "\"")
