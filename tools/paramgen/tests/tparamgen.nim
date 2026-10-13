import std/[unittest, os, strutils, json, tables, sequtils]

import ../lib

const fixtureRoot = "tools/paramgen/tests/fixtures/root"
const workRoot = ".build/paramgen-test/root"

proc freshWorkRoot(): string =
  ## Fixture disalin ke `.build/` supaya test tidak menulis ke dalam tree fixture.
  if dirExists(workRoot):
    removeDir(workRoot)
  createDir(parentDir(workRoot))
  copyDir(fixtureRoot, workRoot)
  workRoot

suite "paramgen: validasi key & tipe":
  test "isValidKey":
    check isValidKey("lending.collectibility.dpd.kl")
    check isValidKey("platform.calendar.fiscal_year_start_month")
    check not isValidKey("lending")
    check not isValidKey("Lending.dpd")
    check not isValidKey("lending..dpd")
    check not isValidKey("lending.dpd.")
    check not isValidKey("lending.2dpd")
    check not isValidKey("lending.dpd-kl")

  test "tipe duration ditolak dengan pesan jelas":
    let node = parseJson("""[{"key":"x.duration.thing","type":"duration","scopes":["GLOBAL"]}]""")
    var raised = false
    try:
      discard parseDefsFromJson("x", node)
    except ParamgenError as e:
      raised = true
      check e.msg.contains("duration")
    check raised

  test "scope ilegal, regex regulasi, dan enum kosong ditolak":
    var msgs: seq[string]
    for bad in [
      """[{"key":"x.a.b","type":"integer","scopes":["MOON"]}]""",
      """[{"key":"x.a.b","type":"integer","scopes":["GLOBAL"],"regulatory_refs":["REG-20"]}]""",
      """[{"key":"x.a.b","type":"enum","scopes":["GLOBAL"]}]""",
      """[{"key":"x.a.b","type":"integer","scopes":["GLOBAL"],"schema":{"minimum":10,"maximum":1}}]""",
      """[{"key":"x.a.b","type":"integer","scopes":["GLOBAL"],"sensitivity":"MAYBE"}]""",
      """[{"key":"y.a.b","type":"integer","scopes":["GLOBAL"]}]""",
    ]:
      try:
        discard parseDefsFromJson("x", parseJson(bad))
        msgs.add("tidak ditolak: " & bad)
      except ParamgenError:
        discard
    check msgs.len == 0

  test "default: description_key diturunkan, requires_approval true":
    let defs = parseDefsFromJson("x", parseJson(
      """[{"key":"x.a.b","type":"integer","scopes":["GLOBAL"]}]"""))
    check defs[0].descriptionKey == "param.x.a.b"
    check defs[0].requiresApproval
    check defs[0].sinceVersion == "0.1.0"
    check defs[0].effectiveFrom == "1970-01-01"

suite "paramgen: generate":
  test "loadAllDefs membaca YAML fixture, urut & lengkap":
    let defs = loadAllDefs(fixtureRoot)
    check defs.len == 5
    check defs[0].key == "deposit.savings.min_balance"
    check defs[^1].key == "platform.calendar.fiscal_year_start_month"
    check defs[0].module == "deposit"
    check defs[0].valueType == "money"
    check defs[0].defaultPack["base"].kind == JString
    let lending = defs.filterIt(it.key == "lending.collectibility.dpd.kl")[0]
    check lending.sensitivity == "CRITICAL"
    check lending.regulatoryRefs == @["REG-204"]
    check lending.scopes == @["INSTITUTION", "SEGMENT"]
    check lending.defaultPack["bpr"].kind == JInt
    check lending.defaultPack["bpr"].getInt == 91

  test "render Nim: const bertipe, metadata, dan import yang perlu saja":
    let nim = renderNim(loadAllDefs(fixtureRoot))
    check nim.contains("const P_lending_collectibility_dpd_kl* = ParamKey[int64]")
    check nim.contains("""ParamKey[Rate]("lending.ppap.rate.kl")""")
    check nim.contains("""ParamKey[Money]("deposit.savings.min_balance")""")
    check nim.contains("""ParamKey[string]("deposit.statement.line_label")""")
    check nim.contains("valueType: pvtInteger")
    check nim.contains("scopes: {pstProduct, pstBranch}")
    check nim.contains("sensitivity: psCritical")
    check nim.contains("requiresApproval: false")
    check nim.contains("regulatoryRefs: @[\"REG-204\"]")
    check nim.contains("import ../paramkey")
    check nim.contains("import ../rate")
    check nim.contains("import ../money")
    check not nim.contains("import ../businessdate") # tidak ada tipe date di fixture
    check not nim.contains("import std/json")
    check nim.startsWith("## JANGAN EDIT")

  test "render TS: tipe TS + metadata":
    let ts = renderTs(loadAllDefs(fixtureRoot))
    check ts.contains("export interface ParamDefinition")
    check ts.contains("\"valueType\": \"money\"")
    check ts.contains("\"tsType\": \"string\"") # uang sebagai string (spec §13)
    check ts.contains("\"tsType\": \"boolean\"") == false
    check ts.contains("as const")
    check ts.contains("\"sensitivity\": \"CRITICAL\"")

  test "render SQL definisi: semua definisi, idempotent, ditandai compliance":
    let defs = loadAllDefs(fixtureRoot)
    let sql = renderDefinitionSql(defs)
    check sql.contains("INSERT INTO platform.param_definition")
    check sql.contains("ON CONFLICT (key) DO UPDATE SET")
    check sql.contains("'lending.collectibility.dpd.kl'")
    check sql.contains("'deposit.savings.min_balance'")
    check sql.contains("ARRAY['INSTITUTION', 'SEGMENT']")
    check sql.contains("ARRAY['REG-204']")
    check sql.contains("NEEDS-COMPLIANCE-REVIEW")
    check not sql.contains("platform.param_value")

  test "render SQL nilai pack: hanya nilai pack itu, idempotent":
    let defs = loadAllDefs(fixtureRoot)
    let sql = renderValuesSql("bpr", defs)
    check sql.contains("INSERT INTO platform.param_value")
    check sql.contains("ON CONFLICT (param_value_id) DO NOTHING")
    check sql.contains("md5('lending.collectibility.dpd.kl|bpr')::uuid")
    check sql.contains("'SEGMENT', 'bpr'")
    check sql.contains("'91'::jsonb")
    check sql.contains("""'"0.5"'::jsonb""")
    check sql.contains("BUKAN fallback kode")
    check not sql.contains("INSERT INTO platform.param_definition")
    # definisi tanpa nilai untuk pack ini tidak ikut
    check not sql.contains("deposit.savings.min_balance")

  test "scope seed: SEGMENT diprioritaskan, GLOBAL memakai scope_id NULL":
    let defs = loadAllDefs(fixtureRoot)
    let base = renderValuesSql("base", defs)
    check base.contains("'GLOBAL', NULL")

  test "packNames hanya pack yang benar-benar dipakai":
    check packNames(loadAllDefs(fixtureRoot)) == @["base", "bpr", "koperasi"]

suite "paramgen: gen & check":
  test "runGen menulis 3 jenis artefak lalu runCheck hijau":
    let root = freshWorkRoot()
    let written = runGen(root)
    var paths: seq[string]
    for o in written: paths.add o.path
    check nimGeneratedPath in paths
    check tsGeneratedPath in paths
    check definitionsPath() in paths
    check valuesPath("bpr") in paths
    check fileExists(root / nimGeneratedPath)
    check fileExists(root / tsGeneratedPath)
    check fileExists(root / definitionsPath())
    check fileExists(root / valuesPath("koperasi"))
    var note = ""
    check runCheck(root, note)
    check note.len == 0

  test "determinisme: generate dua kali identik":
    let root = freshWorkRoot()
    discard runGen(root)
    let a = readFile(root / nimGeneratedPath)
    discard runGen(root)
    check readFile(root / nimGeneratedPath) == a

  test "runCheck gagal setelah artefak diubah (drift terdeteksi)":
    let root = freshWorkRoot()
    discard runGen(root)
    writeFile(root / nimGeneratedPath, readFile(root / nimGeneratedPath) & "\n# drift\n")
    var note = ""
    check not runCheck(root, note)
    check note.contains("berbeda")

  test "runCheck gagal bila artefak belum ada":
    let root = freshWorkRoot()
    var note = ""
    check not runCheck(root, note)
    check note.contains("belum ada")

  test "runCheck mendeteksi definisi baru (YAML berubah)":
    let root = freshWorkRoot()
    discard runGen(root)
    writeFile(root / "modules/lending/seeds/params.yaml",
      readFile(root / "modules/lending/seeds/params.yaml") & """

- key: lending.fee.admin
  type: money
  scopes: [GLOBAL]
  schema: { minimum: 0 }
  default_pack: { base: "1000.00" }
""")
    var note = ""
    check not runCheck(root, note)

  test "key duplikat antar modul ditolak":
    let root = freshWorkRoot()
    writeFile(root / "modules/platform/seeds/params.yaml",
      readFile(root / "modules/platform/seeds/params.yaml") & """

- key: platform.calendar.fiscal_year_start_month
  type: integer
  scopes: [GLOBAL]
  default_pack: { base: 1 }
""")
    var raised = false
    try:
      discard loadAllDefs(root)
    except ParamgenError as e:
      raised = true
      check e.msg.contains("duplikat")
    check raised

  test "modul tanpa seeds/params.yaml tidak menggagalkan generate":
    let root = freshWorkRoot()
    createDir(root / "modules/empty")
    let written = runGen(root)
    check written.len >= 2
