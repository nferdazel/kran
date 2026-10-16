import std/[unittest, json, options, strutils]

import kernel/[paramkey, money, rate, businessdate, result]
import platform/domain/param

proc lookup(pairs: seq[(ParamScopeType, string)]): ScopeValueLookup =
  ## Pemanggil yang meminta tipe-tipe dalam `pairs`; sisanya `none` (= tidak diminta), bukan `""`
  ## (= diminta tanpa id) — perbedaan itulah inti O-012.
  let captured = pairs
  result = proc(scopeType: ParamScopeType): Option[string] =
    for (t, id) in captured:
      if t == scopeType:
        return some(id)
    none(string)

proc cand(scopeType: ParamScopeType, scopeId: string, value: JsonNode): ParamCandidate =
  ParamCandidate(paramValueId: "pv-" & $scopeType, scopeType: scopeType, scopeId: scopeId,
    value: value, effectiveFrom: "2026-01-01")

suite "param: urutan resolusi":
  test "paling spesifik lebih dulu, GLOBAL paling akhir":
    check resolutionRank(pstProduct) < resolutionRank(pstBranch)
    check resolutionRank(pstBranch) < resolutionRank(pstInstitution)
    check resolutionRank(pstInstitution) < resolutionRank(pstSegment)
    check resolutionRank(pstSegment) < resolutionRank(pstRole)
    check resolutionRank(pstRole) < resolutionRank(pstGlobal)
    check resolutionRank(pstProduct) == 0

  test "kandidat scope termirip menang":
    let candidates = @[
      cand(pstGlobal, "", %*91),
      cand(pstInstitution, "inst-1", %*92),
      cand(pstProduct, "prod-1", %*93),
    ]
    let picked = resolveCandidate(candidates, lookup(@[(pstProduct, "prod-1"), (pstBranch, "br-1"),
        (pstInstitution, "inst-1")]))
    check picked.isSome
    check picked.get().value.getInt == 93

  test "scope yang tidak cocok diabaikan (tanpa fallback diam-diam ke scope lain)":
    let candidates = @[
      cand(pstGlobal, "", %*91),
      cand(pstBranch, "br-2", %*99),        # cabang lain
      cand(pstInstitution, "inst-9", %*98), # institusi lain
    ]
    let picked = resolveCandidate(candidates, lookup(@[(pstBranch, "br-1"), (pstInstitution, "inst-1")]))
    check picked.get().scopeType == pstGlobal
    check picked.get().value.getInt == 91

  test "pemanggil tanpa scope sama sekali hanya dapat GLOBAL":
    let candidates = @[cand(pstGlobal, "", %*91), cand(pstInstitution, "inst-1", %*92)]
    let picked = resolveCandidate(candidates, lookup(@[]))
    check picked.get().value.getInt == 91

  test "tidak ada kandidat -> none (pemanggil harus melempar ParamNotFound)":
    check resolveCandidate(@[], lookup(@[])).isNone

suite "param: resolusi scope — batas institusi akar (O-012)":
  test "pemanggil institusi akar (id kosong) membaca nilai INSTITUTION, bukan GLOBAL":
    # Sebelum O-012, uji ini mengharapkan GLOBAL/91: tipe lookup hanya `string`, sehingga `""`
    # berarti "tidak diminta" **dan** "diminta tanpa id", dan kandidat INSTITUTION ber-`scope_id`
    # NULL tidak terjangkau. Setelah tipe jadi `Option`, `some("")` berarti "diminta", dan nilai
    # institusi akar menang karena lebih spesifik daripada GLOBAL.
    let candidates = @[cand(pstGlobal, "", %*91), cand(pstInstitution, "", %*92)]
    let picked = resolveCandidate(candidates, lookup(@[(pstInstitution, "")]))
    check picked.isSome
    check picked.get().scopeType == pstInstitution
    check picked.get().value.getInt == 92

  test "pemanggil yang tidak meminta apa pun tetap hanya dapat GLOBAL":
    let candidates = @[cand(pstGlobal, "", %*91), cand(pstInstitution, "", %*92)]
    let picked = resolveCandidate(candidates, lookup(@[]))
    check picked.get().value.getInt == 91

  test "id kosong tidak membuat tipe yang tidak diminta ikut cocok":
    # Penjaga agar "id kosong" tidak berubah jadi wildcard: pemanggil institusi akar tidak boleh
    # mengambil kandidat BRANCH ber-`scope_id` NULL hanya karena keduanya kosong.
    let candidates = @[cand(pstGlobal, "", %*91), cand(pstBranch, "", %*99)]
    let picked = resolveCandidate(candidates, lookup(@[(pstInstitution, "")]))
    check picked.isSome
    check picked.get().scopeType == pstGlobal
    check picked.get().value.getInt == 91

suite "param: validasi schema (subset)":
  test "type":
    check validateAgainstSchema(%*{"type": "integer"}, %*9) == ""
    check validateAgainstSchema(%*{"type": "integer"}, %*"9").contains("tipe nilai")
    check validateAgainstSchema(%*{"type": "string"}, %*"x") == ""
    check validateAgainstSchema(%*{"type": "boolean"}, %*true) == ""

  test "minimum & maximum":
    let schema = %*{"type": "integer", "minimum": 1, "maximum": 365}
    check validateAgainstSchema(schema, %*91) == ""
    check validateAgainstSchema(schema, %*0).contains("minimum")
    check validateAgainstSchema(schema, %*366).contains("maximum")

  test "minLength, maxLength, enum":
    check validateAgainstSchema(%*{"type": "string", "minLength": 3}, %*"ab")
      .contains("minLength")
    check validateAgainstSchema(%*{"type": "string", "maxLength": 3}, %*"abcd")
      .contains("maxLength")
    let schema = %*{"type": "string", "enum": ["flat", "efektif", "anuitas"]}
    check validateAgainstSchema(schema, %*"flat") == ""
    check validateAgainstSchema(schema, %*"berat").contains("enum")

  test "null dan schema kosong":
    check validateAgainstSchema(%*{"type": "string"}, newJNull()).contains("null")
    check validateAgainstSchema(newJObject(), %*91) == ""

  test "kunci schema di luar subset tidak divalidasi runtime (ditolak paramgen saat build)":
    check validateAgainstSchema(%*{"pattern": "^[0-9]+$"}, %*"bukan angka") == ""

suite "param: konversi bertipe":
  test "integer & bool & string":
    check coerceTo[int64]("k", %*91).value() == 91
    check coerceTo[int64]("k", %*"91").isErr # integer bukan string JSON
    check coerceTo[bool]("k", %*true).value()
    check coerceTo[bool]("k", %*"true").isErr
    check coerceTo[string]("k", %*"mutasi").value() == "mutasi"
    check coerceTo[string]("k", %*1).isErr

  test "money wajib string desimal (hindari float)":
    check coerceTo[Money]("k", %*"10000.00").value() == money(100_000_000)
    check coerceTo[Money]("k", %*1000).isErr
    check coerceTo[Money]("k", %*"bukan uang").isErr

  test "rate dipersentase sebagai string":
    # Rate menyimpan pecahan berskala 10^6: 12,5% -> 125_000 micro; 100% -> 1_000_000.
    check coerceTo[Rate]("k", %*"12.5").value() == rateFromMicro(125_000)
    check coerceTo[Rate]("k", %*"100").value() == rateFromMicro(1_000_000)
    check coerceTo[Rate]("k", %*12.5).isErr
    check coerceTo[Rate]("k", %*"abc").isErr

  test "date ISO sebagai string":
    check coerceTo[BusinessDate]("k", %*"2026-10-13").value().toIso() == "2026-10-13"
    check coerceTo[BusinessDate]("k", %*"2026-02-30").isErr
    check coerceTo[BusinessDate]("k", %*"20261013").isErr

  test "json apa saja":
    check coerceTo[JsonNode]("k", %*{"a": [1, 2]}).value()["a"][1].getInt == 2

  test "checkedValue: schema diperiksa lebih dulu, error menyebut key":
    let schema = %*{"type": "integer", "minimum": 1, "maximum": 365}
    check checkedValue[int64]("lending.dpd", %*91, schema).value() == 91
    let gagal = checkedValue[int64]("lending.dpd", %*400, schema)
    check gagal.isErr
    check gagal.error().kind == pekSchemaViolation
    check gagal.error().key == "lending.dpd"
    check ($gagal.error()).contains("lending.dpd")
    let salahTipe = checkedValue[int64]("x.y", %*"91", %*{"type": "integer"})
    check salahTipe.isErr
