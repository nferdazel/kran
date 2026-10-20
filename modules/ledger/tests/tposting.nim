## Unit test posting rule (T-074): containment, pemilihan, template, pembentukan baris.

import std/[json, unittest]

import kernel/[ids, money]
import ../api

let
  ruleId = Id("22222222-2222-7222-8222-222222222222")
  branch = Id("11111111-1111-7111-8111-111111111111")

proc rule(eventType = "DepositPosted", product = "", conditions = "{}",
          priority = 100): PostingRule =
  PostingRule(ruleId: ruleId, eventType: eventType, productCode: product,
    conditions: parseJson(conditions), priority: priority,
    lines: @[
      PostingRuleLine(lineNo: 1, side: nsDebit, glAccount: "101"),
      PostingRuleLine(lineNo: 2, side: nsCredit, glAccount: "201")])

suite "posting: containment & pencocokan":
  test "kondisi kosong cocok dengan payload apa pun":
    check jsonContains(parseJson("""{"a": 1}"""), parseJson("{}"))
    check rule().ruleMatches("DepositPosted", parseJson("""{"amount": "1.0000"}"""))

  test "kondisi adalah subset rekursif":
    let r = rule(conditions = """{"product": "SAV", "meta": {"channel": "TELLER"}}""")
    check r.ruleMatches("DepositPosted",
      parseJson("""{"product": "SAV", "meta": {"channel": "TELLER", "x": 1}, "amount": "1.0000"}"""))
    check not r.ruleMatches("DepositPosted",
      parseJson("""{"product": "SAV", "meta": {"channel": "MOBILE"}}"""))
    check not r.ruleMatches("DepositPosted", parseJson("""{"product": "SAV"}"""))

  test "product_code pada rule harus sama dengan payload.product":
    check rule(product = "SAV").ruleMatches("DepositPosted", parseJson("""{"product": "SAV"}"""))
    check not rule(product = "SAV").ruleMatches("DepositPosted", parseJson("""{"product": "DEP"}"""))
    check not rule(product = "SAV").ruleMatches("DepositPosted", parseJson("{}"))

  test "event type berbeda tidak cocok":
    check not rule().ruleMatches("FeeCharged", parseJson("{}"))

suite "posting: pemilihan rule":
  let payload = parseJson("""{"product": "SAV", "amount": "1.0000"}""")

  test "rule paling spesifik menang":
    let general = rule(priority = 10)
    let specific = rule(conditions = """{"product": "SAV"}""", priority = 200)
    let chosen = selectRule(@[general, specific], "DepositPosted", payload)
    check chosen.ruleId == ruleId
    check conditionCount(chosen.conditions) == 1

  test "spesifisitas sama → priority terkecil":
    var a = rule(priority = 50)
    a.ruleId = Id("33333333-3333-7333-8333-333333333333")
    var b = rule(priority = 10)
    b.ruleId = Id("44444444-4444-7444-8444-444444444444")
    check selectRule(@[a, b], "DepositPosted", payload).ruleId == b.ruleId

  test "tidak ada rule dan ambigu = ValueError":
    expect ValueError:
      discard selectRule(@[], "DepositPosted", payload)
    var a = rule()
    a.ruleId = Id("33333333-3333-7333-8333-333333333333")
    var b = rule()
    b.ruleId = Id("44444444-4444-7444-8444-444444444444")
    expect ValueError:
      discard selectRule(@[a, b], "DepositPosted", payload)

suite "posting: template & baris":
  test "template Fase 1 wajib 1 debit + 1 kredit":
    check validateTemplate(@[
      PostingRuleLine(lineNo: 1, side: nsDebit, glAccount: "101"),
      PostingRuleLine(lineNo: 2, side: nsCredit, glAccount: "201")]).len == 2
    expect ValueError:
      discard validateTemplate(@[
        PostingRuleLine(lineNo: 1, side: nsDebit, glAccount: "101"),
        PostingRuleLine(lineNo: 2, side: nsDebit, glAccount: "102")])
    expect ValueError:
      discard validateTemplate(@[
        PostingRuleLine(lineNo: 1, side: nsDebit, glAccount: "")])

  test "baris jurnal memakai nominal event dan branch event":
    let lines = buildLines(rule(), money(150_0000), branch)
    check lines.len == 2
    check lines[0].debit == money(150_0000)
    check lines[0].credit.isZero
    check lines[1].credit == money(150_0000)
    check lines[1].debit.isZero
    check lines[0].branchId == branch
    check lines[0].glAccount == "101" and lines[1].glAccount == "201"
    check isBalanced(lines)

  test "nominal nol ditolak":
    expect ValueError:
      discard buildLines(rule(), zero(), branch)
