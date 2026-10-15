## Logging terstruktur (JSON satu baris) tanpa PII (spec §12.1, §18.2).
##
## Aturan yang dipegang modul ini:
##   - Satu baris = satu objek JSON; field selalu urut sama (deterministik, enak di-grep).
##   - **Tidak ada PII/secret**: field dengan nama sensitif (`nik`, `npwp`, `phone`, `email`,
##     `address`, `password`, `secret`, `token`, `pin`, `cvv`, `card`) otomatis di-mask, dan
##     nilai yang benar-benar sensitif dibungkus `mask()` sebelum dicatat.
##   - `trace_id` (= `request_id`) disertakan bila ada, supaya bisa ditelusuri lintas service.
##
## Masking di sini **pertahanan kedua**, bukan pengganti aturan: jangan pernah mengirim PII
## ke logger. (Redis/field-level encryption & blind index: task lain, spec §18.2.)

import std/[json, strutils, times]

type
  Level* = enum
    lvlDebug = "debug"
    lvlInfo = "info"
    lvlWarn = "warn"
    lvlError = "error"

  LogSink* = proc(line: string) {.closure, gcsafe.}

  Logger* = object
    level*: Level
    app*: string
    sink*: LogSink

const
  sensitiveKeys* = [
    "nik", "npwp", "phone", "msisdn", "email", "address", "alamat", "password", "passwd",
    "secret", "token", "pin", "cvv", "card", "rekening", "account_number", "no_hp",
  ]
  maskKeepSuffix* = 4

proc stderrSink(line: string) {.gcsafe.} =
  stderr.writeLine(line)

proc newLogger*(level = lvlInfo, app = "kran", sink: LogSink = nil): Logger =
  result.level = level
  result.app = app
  result.sink = if sink.isNil: LogSink(stderrSink) else: sink

proc isSensitiveKey*(key: string): bool =
  let k = key.toLowerAscii().replace("-", "_")
  for s in sensitiveKeys:
    if k == s or k.contains(s):
      return true
  false

proc mask*(value: string): string =
  ## Menyisakan potongan akhir untuk korelasi manual; sisanya jadi `*`.
  if value.len == 0:
    return ""
  if value.len <= maskKeepSuffix:
    return repeat('*', value.len)
  repeat('*', value.len - maskKeepSuffix) & value[^maskKeepSuffix .. ^1]

proc utcIso(now: DateTime): string =
  ## ISO-8601 UTC milidetik (`2026-10-13T08:00:00.123Z`) — spec §13 memakai ISO-8601.
  now.utc.format("yyyy-MM-dd'T'HH:mm:ss'.'fff'Z'")

proc logMessage*(l: Logger, level: Level, msg: string,
                 fields: openArray[(string, string)] = [],
                 traceId = "", now = now()): string =
  ## Membangun (dan mengirim) satu baris log. Mengembalikan barisnya supaya bisa diuji.
  if level < l.level:
    return ""
  var node = newJObject()
  node["ts"] = %utcIso(now)
  node["level"] = %($level)
  node["app"] = %l.app
  node["msg"] = %msg
  if traceId.len > 0:
    node["trace_id"] = %traceId
  for (k, v) in fields:
    node[k] = %(if isSensitiveKey(k): mask(v) else: v)
  result = $node
  if not l.sink.isNil:
    l.sink(result)

proc debug*(l: Logger, msg: string, fields: openArray[(string, string)] = [],
            traceId = ""): string =
  logMessage(l, lvlDebug, msg, fields, traceId)

proc info*(l: Logger, msg: string, fields: openArray[(string, string)] = [],
           traceId = ""): string =
  logMessage(l, lvlInfo, msg, fields, traceId)

proc warn*(l: Logger, msg: string, fields: openArray[(string, string)] = [],
           traceId = ""): string =
  logMessage(l, lvlWarn, msg, fields, traceId)

proc error*(l: Logger, msg: string, fields: openArray[(string, string)] = [],
            traceId = ""): string =
  logMessage(l, lvlError, msg, fields, traceId)

proc parseLevel*(s: string, default = lvlInfo): Level =
  case s.strip().toLowerAscii()
  of "debug": lvlDebug
  of "info": lvlInfo
  of "warn", "warning": lvlWarn
  of "error": lvlError
  else: default
