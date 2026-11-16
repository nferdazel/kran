## Lint anti-magic-number (spec §10.4).
##
## Aturan: **tidak ada nilai bisnis di kode**. Nilai bisnis (rate, limit, fee, ambang,
## persentase PPAP, tarif pajak, DPD, …) harus berasal dari parameter DB (`platform/param`),
## bukan literal di `domain/` atau `application/`.
##
## Cakupan pemindaian: `modules/<m>/domain/**`, `modules/<m>/application/**`, dan
## `apps/api/src/**` (spec §10.4, T-174). Handler di `apps/api/src` adalah composition root:
## literal di sana bisa langsung menjadi angka yang masuk ledger, jadi gate harus melihatnya.
## `tests/`, `generated/`, dan `shared/kernel/**` dilewati — kernel memang memuat konstanta
## teknis & invarian matematis.
##
## Batas kemampuan (jujur): deteksi string bersifat **pola** (numerik/uang/persen), bukan
## semantik. String seperti "batas harian" tidak bisa dikenali sebagai nilai bisnis oleh tool
## ini; itu tugas review. Deteksi angka bersifat pasti (allowlist teknis).
##
## Escape hatch: `# nomagic:ok <alasan-obligatoris>` pada baris yang sama.
##
## Baseline (`tools/lint-nomagic/baseline.txt`) menampung temuan yang sudah ada sebelum cakupan
## `apps/api/src` hidup. Sama seperti `tools/archcheck/baseline.txt`: baseline hanya boleh
## menyusut. Temuan baru = gagal, entri yang temuannya sudah hilang = gagal ("baseline stale,
## shrink it"). Temuan di baseline adalah utang, bukan izin.

import std/[strutils, os, sets, algorithm]

type
  Violation* = object
    path*: string
    line*: int
    ## Jenis temuan: `int`, `dec`, `str`, atau `hatch`. Bagian dari kunci baseline supaya
    ## "angka 91" dan "string \"91\"" tidak saling menutupi.
    rule*: string
    ## Nilai literal yang dilanggar, tanpa nomor baris. Nomor baris bergeser tiap edit;
    ## nilainya tidak, jadi kunci baseline memakai ini (pola `tools/archcheck/baseline.txt`).
    value*: string
    message*: string

const
  ## Konstanta **teknis** yang boleh ada di kode (spec §10.4 menyebut contoh 0, 1, 12, 100).
  allowedInts = [0'i64, 1'i64, 2'i64, 12'i64, 24'i64, 60'i64, 100'i64, 1000'i64, 1024'i64]
  ## Konstanta teknis yang hanya berlaku di `apps/api/src` (composition root), **tidak** di
  ## `modules/<m>/domain|application`. Tanpa pemisahan ini, melonggarkan handler berarti ikut
  ## melonggarkan modul — mis. `200` sebagai plafon bisnis di domain akan lolos.
  ##
  ## Isinya sengaja himpunan tertutup, bukan "apa pun yang merah hari ini":
  ##  - kode status HTTP yang dipakai API ini (RFC 9110 registry);
  ##  - batas port: 8080 (port dev) dan 65535 (port maksimum).
  ## Angka teknis lain (timeout, ukuran buffer, exit code CLI) **tidak** masuk sini; ia duduk di
  ## baseline sebagai utang yang harus menyusut (T-174).
  handlerAllowedInts = [
    200'i64, 201'i64, 204'i64, 300'i64, 400'i64, 401'i64, 403'i64, 404'i64, 405'i64,
    409'i64, 415'i64, 426'i64, 429'i64, 500'i64, 501'i64, 503'i64,
    8080'i64, 65535'i64,
  ]
  hatch = "# nomagic:ok"

proc isScanned*(rel: string): bool =
  let r = rel.replace('\\', '/')
  if r.contains("/tests/") or r.contains("/generated/") or r.startsWith("shared/"):
    return false
  if r.startsWith("apps/api/src/"):
    return true
  if not r.startsWith("modules/"):
    return false
  let parts = r.split('/')
  parts.len >= 4 and parts[2] in ["domain", "application"]

proc isHandlerPath*(rel: string): bool =
  ## `apps/api/src` (composition root) — satu-satunya tempat `handlerAllowedInts` berlaku.
  rel.replace('\\', '/').startsWith("apps/api/src/")

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
  let lines = source.splitLines()
  # Berkas hasil generator (`tools/gen-version.sh`) tidak ditulis tangan: isinya stempel dari
  # `VERSION`, dan nilainya berubah setiap rilis. Tanpa lewatan ini, setiap bump versi memunculkan
  # "temuan baru" sekaligus membuat entri baseline lama basi — gate merah karena rilis, bukan
  # karena ada nilai bisnis yang masuk kode. Konvensi penandanya sama dengan header generator.
  if lines.len > 0 and lines[0].contains("JANGAN EDIT"):
    return @[]
  for idx, raw in lines.pairs():
    let lineNo = idx + 1
    let okPos = raw.find(hatch)
    if okPos >= 0:
      if raw[okPos + len(hatch) .. ^1].strip().len == 0:
        result.add Violation(path: relPath, line: lineNo, rule: "hatch", value: "",
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
          result.add Violation(path: relPath, line: lineNo, rule: "str", value: s,
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
            result.add Violation(path: relPath, line: lineNo, rule: "dec", value: digits,
              message: "literal desimal dianggap nilai bisnis: " & digits)
          else:
            let v = parseAllowed(digits)
            let handlerTechnical = isHandlerPath(relPath) and v in handlerAllowedInts
            if v != low(int64) and v notin allowedInts and not handlerTechnical:
              result.add Violation(path: relPath, line: lineNo, rule: "int", value: digits,
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

proc baselineKey*(v: Violation): string =
  ## Kunci baseline sengaja tanpa nomor baris: baris bergeser tiap edit, temuannya tidak.
  v.rule & "|" & v.path & "|" & v.value

proc parseBaseline*(text: string): seq[string] =
  ## Satu entri per baris, `#` = komentar. Urutan tidak penting saat dibaca.
  for raw in text.splitLines():
    let line = raw.strip()
    if line.len == 0 or line.startsWith("#"):
      continue
    result.add line

type BaselineDiff* = object
  newViolations*: seq[Violation]
  staleEntries*: seq[string]

proc compareBaseline*(violations: seq[Violation],
                      entries: seq[string]): BaselineDiff =
  ## Tiga hasil: cocok, temuan baru (gagal), entri basi (gagal, baseline harus menyusut).
  var accepted = initHashSet[string]()
  for e in entries:
    accepted.incl e
  var matched = initHashSet[string]()
  for v in violations:
    let key = baselineKey(v)
    if key in accepted:
      matched.incl key
    else:
      result.newViolations.add v
  for e in entries:
    if e notin matched:
      result.staleEntries.add e

proc renderBaseline*(violations: seq[Violation]): string =
  ## Tulis baseline awal: unik dan terurut, supaya diff-nya bisa dibaca manusia.
  var keys = initHashSet[string]()
  for v in violations:
    keys.incl baselineKey(v)
  var sorted: seq[string]
  for k in keys:
    sorted.add k
  sorted.sort()
  result = "# lint-nomagic baseline — temuan yang diterima sebagai utang. HANYA BOLEH MENYUSUT.\n"
  result.add "# format: rule|path|nilai. Hapus satu baris saat temuannya diperbaiki.\n"
  for k in sorted:
    result.add k & "\n"
