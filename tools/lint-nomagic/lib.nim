## Lint anti-magic-number (spec §10.4).
##
## Aturan: **tidak ada nilai bisnis di kode**. Nilai bisnis (rate, limit, fee, ambang,
## persentase PPAP, tarif pajak, DPD, …) harus berasal dari parameter DB (`platform/param`),
## bukan literal di `domain/` atau `application/`.
##
## Cakupan pemindaian: `modules/<m>/domain/**` dan `modules/<m>/application/**` saja
## (spec §10.4). `tests/`, `generated/`, dan `shared/kernel/**` dilewati — kernel memang
## memuat konstanta teknis & invarian matematis.
##
## Batas kemampuan (jujur): deteksi string bersifat **pola** (numerik/uang/persen), bukan
## semantik. String seperti "batas harian" tidak bisa dikenali sebagai nilai bisnis oleh tool
## ini; itu tugas review. Deteksi angka bersifat pasti (allowlist teknis).
##
## Escape hatch: `# nomagic:ok <alasan-obligatoris>` pada baris yang sama.

import std/[strutils, os]

type
  Violation* = object
    path*: string
    line*: int
    message*: string

const
  ## Konstanta **teknis** yang boleh ada di kode (spec §10.4 menyebut contoh 0, 1, 12, 100).
  allowedInts = [0'i64, 1'i64, 2'i64, 12'i64, 24'i64, 60'i64, 100'i64, 1000'i64, 1024'i64]
  hatch = "# nomagic:ok"

proc isScanned*(rel: string): bool =
  let r = rel.replace('\\', '/')
  if r.contains("/tests/") or r.contains("/generated/") or r.startsWith("shared/"):
    return false
  if not r.startsWith("modules/"):
    return false
  let parts = r.split('/')
  parts.len >= 4 and parts[2] in ["domain", "application"]

proc isIdentChar(c: char): bool {.inline.} =
  c in {'a' .. 'z', 'A' .. 'Z', '0' .. '9', '_'}

proc isBusinessString*(s: string): bool =
  ## Pola string yang jelas-jelas nilai bisnis: nominal rupiah, angka persen, angka telanjang.
  let t = s.strip()
  if t.len == 0:
    return false
  if t.len >= 2 and t[0] in {'R', 'r'} and t[1] in {'p', 'P'}:
    return true
  var body = t
  if body.len > 0 and body[^1] == '%':
    body = body[0 ..< body.len - 1]
  var digits = 0
  var seps = 0
  for c in body:
    if c in {'0' .. '9'}:
      inc digits
    elif c in {'.', ','}:
      inc seps
    else:
      return false
  if digits == 0:
    return false
  if seps > 0:
    return true
  digits >= 2

proc parseAllowed(digits: string): int64 =
  ## Mengembalikan nilai, atau `low(int64)` (penanda "tidak bisa diparse") — nilai
  ## sebesar itu mustahil muncul di kode sebagai literal biasa.
  try:
    parseBiggestInt(digits)
  except ValueError, OverflowDefect:
    low(int64)

proc scanSource*(relPath, source: string): seq[Violation] =
  if not isScanned(relPath):
    return @[]
  for idx, raw in source.splitLines().pairs():
    let lineNo = idx + 1
    let okPos = raw.find(hatch)
    if okPos >= 0:
      if raw[okPos + len(hatch) .. ^1].strip().len == 0:
        result.add Violation(path: relPath, line: lineNo,
          message: "escape hatch `" & hatch & "` tanpa alasan")
      continue

    var i = 0
    while i < raw.len:
      let c = raw[i]
      if c == '#':
        break
      elif c == '"':
        var j = i + 1
        var s = ""
        while j < raw.len and raw[j] != '"':
          if raw[j] == '\\' and j + 1 < raw.len:
            if raw[j + 1] == 'n':
              s.add('\n')
            else:
              s.add(raw[j + 1])
            j += 2
          else:
            s.add(raw[j])
            inc j
        if isBusinessString(s):
          result.add Violation(path: relPath, line: lineNo,
            message: "literal string bernilai bisnis: \"" & s & "\"")
        i = j + 1
      elif c == '\'':
        var j = i + 1
        while j < raw.len and raw[j] != '\'':
          if raw[j] == '\\': j += 2 else: inc j
        i = j + 1
      elif c in {'0' .. '9'}:
        let prev = if i > 0: raw[i - 1] else: ' '
        var j = i
        var digits = ""
        var hasDot = false
        while j < raw.len and (raw[j] in {'0' .. '9', '_', '.'}):
          if raw[j] == '.':
            if hasDot: break
            hasDot = true
            digits.add('.')
          elif raw[j] != '_':
            digits.add(raw[j])
          inc j
        if not isIdentChar(prev):
          if hasDot:
            result.add Violation(path: relPath, line: lineNo,
              message: "literal desimal dianggap nilai bisnis: " & digits)
          else:
            let v = parseAllowed(digits)
            if v != low(int64) and v notin allowedInts:
              result.add Violation(path: relPath, line: lineNo,
                message: "angka " & digits & " bukan konstanta teknis; pakai parameter DB")
        i = j
      else:
        inc i

proc scanRoot*(root: string): seq[Violation] =
  let skipDirs = [".git", ".build", "node_modules", ".local", "nimcache"]
  for path in walkDirRec(root, yieldFilter = {pcFile}):
    let rel = relativePath(path, root).replace('\\', '/')
    var skip = false
    for d in skipDirs:
      if rel.startsWith(d & "/") or rel.contains("/" & d & "/"):
        skip = true
        break
    if skip or not rel.endsWith(".nim") or not isScanned(rel):
      continue
    var source = ""
    try:
      source = readFile(path)
    except CatchableError:
      continue
    result.add scanSource(rel, source)

proc formatViolation*(v: Violation): string =
  v.path & ":" & $v.line & ": " & v.message
