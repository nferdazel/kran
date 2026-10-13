import std/[unittest, json, strutils]

import "platform-lib/log"

suite "log: format & level":
  test "satu baris JSON valid, field inti ada":
    let l = newLogger(lvlInfo, "cbs-test", sink = proc(line: string) {.gcsafe.} = discard)
    let line = l.info("migrasi selesai", {"applied": "3", "trace_id": "abc"})
    check line.len > 0
    check not line.contains('\n')
    let node = parseJson(line)
    check node["level"].getStr == "info"
    check node["app"].getStr == "cbs-test"
    check node["msg"].getStr == "migrasi selesai"
    check node["applied"].getStr == "3"
    check node["ts"].getStr.endsWith("Z")
    check node["trace_id"].getStr == "abc"

  test "level di bawah ambang tidak dicetak":
    let l = newLogger(lvlWarn, "cbs-test", sink = proc(line: string) {.gcsafe.} = discard)
    check l.debug("tidak terlihat").len == 0
    check l.info("tidak terlihat").len == 0
    check l.warn("terlihat").len > 0
    check l.error("terlihat").len > 0

  test "field tetap urut (deterministik, enak di-grep)":
    let l = newLogger(lvlInfo, "a", sink = proc(line: string) {.gcsafe.} = discard)
    let line = l.info("x", {"z": "2", "y": "1"}, traceId = "t")
    let posTs = line.find("\"ts\":")
    let posLevel = line.find("\"level\":")
    let posMsg = line.find("\"msg\":")
    let posTrace = line.find("\"trace_id\":")
    let posY = line.find("\"y\":")
    let posZ = line.find("\"z\":")
    check posTs >= 0 and posTs < posLevel
    check posLevel < posMsg
    check posMsg < posTrace
    check posTrace < posZ
    # urutan field mengikuti urutan pemanggil (z diminta lebih dulu)
    check posZ < posY

suite "log: tanpa PII":
  test "nilai dengan kunci sensitif otomatis di-mask":
    let l = newLogger(lvlInfo, "a", sink = proc(line: string) {.gcsafe.} = discard)
    let line = l.info("kyc", {"nik": "3174091234560001", "phone": "081234567890",
                              "email": "budi@example.com", "party_id": "0199-abc"})
    check not line.contains("3174091234560001")
    check not line.contains("081234567890")
    check not line.contains("budi@example.com")
    check line.contains("party_id")
    let node = parseJson(line)
    check node["nik"].getStr == "************0001"
    check node["phone"].getStr == "********7890"
    check node["party_id"].getStr == "0199-abc"

  test "isSensitiveKey mengenali varian nama":
    check isSensitiveKey("nik")
    check isSensitiveKey("NPWP")
    check isSensitiveKey("no_hp")
    check isSensitiveKey("account-number")
    check not isSensitiveKey("party_id")
    check not isSensitiveKey("business_date")

  test "mask: pendek disamarkan seluruhnya, kosong tetap kosong":
    check mask("") == ""
    check mask("1234") == "****"
    check mask("12345") == "*2345"
    check mask("3174091234560001").len == 16

  test "parseLevel":
    check parseLevel("DEBUG") == lvlDebug
    check parseLevel(" warning ") == lvlWarn
    check parseLevel("ngawur") == lvlInfo
