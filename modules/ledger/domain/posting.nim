## Posting rule (T-074): peta accounting event → template jurnal. Murni, tanpa I/O.
##
## Aturan pemilihan rule (D-073):
##   1. `eventType` harus sama dan `productCode` (bila diisi) harus sama dengan `payload.product`.
##   2. Kondisi rule harus **subset** payload (containment JSON).
##   3. Rule paling **spesifik** (kondisi terbanyak) menang; seri → `priority` terkecil.
##   4. Masih seri → **ambigu**: gagal terlihat (event masuk DEAD), bukan dipilih diam-diam.

import std/[json, strutils]

import kernel/[ids, money]
import ./coa, ./journal

type
  PostingRuleLine* = object
    lineNo*: int
    side*: NormalSide
    glAccount*: string

  PostingRule* = object
    ruleId*: Id
    eventType*: string
    productCode*: string ## "" = berlaku untuk semua produk
    conditions*: JsonNode
    priority*: int
    lines*: seq[PostingRuleLine]

proc jsonContains*(container, expected: JsonNode): bool =
  ## Apakah `container` memuat `expected` (subset rekursif untuk objek; skalar = sama).
  if expected.kind == JObject:
    if container.kind != JObject:
      return false
    for key, value in expected:
      if not container.hasKey(key) or not jsonContains(container[key], value):
        return false
    return true
  if expected.kind == JArray:
    return container.kind == JArray and $container == $expected
  if expected.kind == JNull:
    return container.kind == JNull
  $container == $expected

proc conditionCount*(node: JsonNode): int =
  ## Jumlah kunci kondisi tingkat atas; dipakai sebagai ukuran kekhususan.
  if node.kind != JObject:
    return 0
  node.len

proc specificityOf*(rule: PostingRule): int =
  ## Kekhususan rule = jumlah kondisi + 1 bila rule dibatasi produk. Tanpa ini, rule produk dengan
  ## kondisi kosong akan seri dengan rule generik dan membuat event produk itu ambigu.
  conditionCount(rule.conditions) + (if rule.productCode.len > 0: 1 else: 0)

proc ruleMatches*(rule: PostingRule, eventType: string, payload: JsonNode): bool =
  if rule.eventType != eventType:
    return false
  if rule.productCode.len > 0:
    if payload.kind != JObject or not payload.hasKey("product"):
      return false
    if payload["product"].kind != JString or
        payload["product"].getStr() != rule.productCode:
      return false
  if rule.conditions.isNil:
    return true
  jsonContains(payload, rule.conditions)

proc selectRule*(rules: openArray[PostingRule], eventType: string,
                 payload: JsonNode): PostingRule =
  ## Memilih satu rule; tidak ada / ambigu = `ValueError` (pemanggil menandai event gagal).
  var best: seq[PostingRule]
  var bestSpecificity = -1
  var bestPriority = 0
  for rule in rules:
    if not ruleMatches(rule, eventType, payload):
      continue
    let spec = specificityOf(rule)
    if spec > bestSpecificity or (spec == bestSpecificity and rule.priority < bestPriority):
      bestSpecificity = spec
      bestPriority = rule.priority
      best = @[rule]
    elif spec == bestSpecificity and rule.priority == bestPriority:
      best.add rule
  if best.len == 0:
    raise newException(ValueError,
      "tidak ada posting rule aktif untuk event " & eventType)
  if best.len > 1:
    raise newException(ValueError,
      "posting rule ambigu untuk event " & eventType & " (" & $best.len & " kandidat)")
  best[0]

proc validateTemplate*(lines: openArray[PostingRuleLine]): seq[PostingRuleLine] =
  ## Fase 1: tepat satu DEBIT + satu CREDIT (nominal tunggal). Split multi-baris = T-076.
  var debits, credits = 0
  var seen: seq[int]
  for l in lines:
    if l.lineNo in seen:
      raise newException(ValueError, "nomor baris template ganda: " & $l.lineNo)
    seen.add l.lineNo
    if l.glAccount.strip.len == 0:
      raise newException(ValueError, "akun template wajib diisi")
    case l.side
    of nsDebit: debits.inc
    of nsCredit: credits.inc
    result.add l
  if debits != 1 or credits != 1:
    raise newException(ValueError,
      "template Fase 1 harus tepat satu DEBIT dan satu CREDIT (dapat " & $debits & "/" & $credits & ")")

proc buildLines*(rule: PostingRule, amount: Money, branchId: Id): seq[JournalLine] =
  ## Baris jurnal dari template; nominal sama untuk sisi debit dan kredit.
  if not (amount > zero()):
    raise newException(ValueError, "nominal event harus lebih besar dari nol")
  let lines = validateTemplate(rule.lines)
  for i, l in lines:
    result.add JournalLine(
      lineNo: i + 1,
      glAccount: l.glAccount,
      branchId: branchId,
      debit: (if l.side == nsDebit: amount else: zero()),
      credit: (if l.side == nsCredit: amount else: zero()))
