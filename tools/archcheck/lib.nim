## Logika penegak batas arsitektur (spec §5.1, §6.3). Murni: bisa diuji tanpa spawn proses.
##
## Model yang dipakai (arah dependensi ke dalam):
##   - `domain` boleh import: stdlib murni, `kernel`, sesama berkas domain modulnya sendiri.
##   - `application` boleh import: domain modulnya sendiri, stdlib (kecuali driver), `kernel`.
##   - `infrastructure`/`interface` mengimplementasikan port; boleh import lebih bebas,
##     tetapi tetap tidak boleh menembus **internal modul lain**.
##   - Modul hanya bicara lewat `api.nim` modul lain (spec §5.5).
##   - `shared/kernel` hanya stdlib & sesama kernel.
##   - `apps/api/src` (handler) dan `*/tests/` (test) punya aturannya sendiri: keduanya
##     tidak boleh menyentuh `infrastructure`/`domain` modul lain (T-173).
##
## Escape hatch: `# archcheck:ok <alasan-obligatoris>` pada baris import yang sama.
##
## Baseline (`tools/archcheck/baseline.txt`) menampung pelanggaran yang sudah ada sebelum
## aturan ini hidup. Baseline hanya boleh menyusut: pelanggaran baru = gagal, entri yang
## pelanggarannya sudah hilang = gagal ("baseline stale, shrink it").

import std/[strutils, os, algorithm, sets]

type
  Category* = enum
    catSkip
    catDomain
    catApplication
    catInfrastructure
    catInterface
    catModuleApi
    catKernel
    catHandler
    catTest

  Violation* = object
    path*: string
    line*: int
    rule*: string ## "A" (domain) | "B" (application) | "C" (batas modul) | "D" (kernel) | "E" (escape hatch) | "F" (handler) | "G" (test)
    message*: string
    imp*: string ## import yang dilanggar, tanpa tanda kutip; dipakai sebagai kunci baseline

const
  layerNames = ["domain", "application", "infrastructure", "interface"]
  ## Awalan yang bukan nama modul bisnis; import ke sini tidak dianggap menembus modul.
  knownRoots = ["std", "kernel", "pkg", "apps", "tools", "shared", "modules", "system",
                "platform-lib"]
  ## Nama modul bisnis menurut spec §7/§8. `scanRoot` menggantinya dengan daftar nyata dari
  ## struktur direktori; daftar ini hanya default supaya pemeriksaan teks tetap bisa diuji.
  ## Import ke paket pihak ketiga (`db_connector/...`) bukan pelanggaran batas modul.
  knownModuleNames* = ["platform", "party", "product", "deposit", "lending", "teller",
                       "ledger", "daycloser", "compliance", "reporting", "tax", "coop",
                       "sharia"]
  hatch = "# archcheck:ok"

proc unquote*(s: string): string =
  ## Nim mengizinkan `import "platform-lib/db/pool"` (perlu untuk nama dir ber-tanda hubung).
  if s.len >= 2 and s[0] == '"' and s[^1] == '"':
    s[1 .. ^2]
  else:
    s

proc normalizeImport*(imp: string): string =
  ## Buang `./` dan `../` berulang supaya bentuk relatif dan bentuk `-p:modules` sama.
  var s = unquote(imp.strip())
  while s.startsWith("./") or s.startsWith("../"):
    if s.startsWith("./"):
      s = s[2 .. ^1]
    else:
      s = s[3 .. ^1]
  s

proc classify*(rel: string): tuple[category: Category, module: string] =
  let r = rel.replace('\\', '/')
  if r.startsWith("tools/") or r.contains("/generated/"):
    return (catSkip, "")
  if r.startsWith("apps/api/src/"):
    return (catHandler, "")
  if r.contains("/tests/"):
    # Test modul boleh memakai internal modulnya sendiri, bukan internal modul lain.
    if r.startsWith("modules/"):
      let parts = r.split('/')
      if parts.len >= 3:
        return (catTest, parts[1])
    return (catTest, "")
  if r.startsWith("shared/kernel/"):
    return (catKernel, "")
  if r.startsWith("modules/"):
    let parts = r.split('/')
    if parts.len < 3:
      return (catSkip, "")
    let m = parts[1]
    case parts[2]
    of "domain": (catDomain, m)
    of "application": (catApplication, m)
    of "infrastructure": (catInfrastructure, m)
    of "interface": (catInterface, m)
    elif parts[2] == "api.nim": (catModuleApi, m)
    else: (catSkip, m)
  else:
    (catSkip, "")

proc expandBracketForm*(item: string): seq[string] =
  ## `std/[asyncdispatch, net]` -> @["std/asyncdispatch", "std/net"].
  let open = item.find('[')
  if open < 0:
    return @[item]
  let close = item.rfind(']')
  if close < open:
    return @[item]
  let prefix = item[0 ..< open]
  result = @[]
  for part in item[open + 1 ..< close].split(','):
    let p = part.strip()
    if p.len > 0:
      result.add(prefix & p)

proc splitTopLevel*(body: string): seq[string] =
  ## Pisah `a, b/[c, d]` hanya pada koma di luar bracket: bentuk bracket punya koma sendiri.
  var depth = 0
  var cur = ""
  for ch in body:
    case ch
    of '[':
      inc depth
      cur.add ch
    of ']':
      if depth > 0: dec depth
      cur.add ch
    of ',':
      if depth > 0:
        cur.add ch
      else:
        result.add cur
        cur = ""
    else:
      cur.add ch
  if cur.strip().len > 0:
    result.add cur

proc bracketDepth*(s: string): int =
  ## Kedalaman `[` yang belum ditutup: import bentuk bracket boleh terlipat ke baris berikutnya.
  for ch in s:
    if ch == '[': inc result
    elif ch == ']': dec result

proc importsOf*(line: string): seq[string] =
  ## Ambil daftar modul yang di-import pada satu baris sumber (termasuk `from`/`include`).
  let t = line.strip()
  if t.find('#') == 0:
    return @[]
  let body =
    if t.startsWith("import "):
      t[7 .. ^1]
    elif t.startsWith("from "):
      let cut = t.find(" import ")
      if cut < 0: return @[] else: t[5 ..< cut]
    elif t.startsWith("include "):
      t[8 .. ^1]
    else:
      return @[]
  for raw in splitTopLevel(body):
    var item = raw.strip()
    let hashPos = item.find('#')
    if hashPos >= 0:
      item = item[0 ..< hashPos].strip()
    if item.len == 0:
      continue
    for expanded in expandBracketForm(item):
      let e = expanded.strip()
      if e.len > 0:
        result.add(e)

proc stripOwnModule*(n, ownModule: string): string =
  ## Import ke modul sendiri ditulis sebagai `<m>/<lapisan>/...` bila memakai `-p:modules`.
  if ownModule.len > 0 and n.startsWith(ownModule & "/"):
    return n[ownModule.len + 1 .. ^1]
  n

proc layerOf*(n: string): string =
  ## Nama lapisan bila path menunjuk ke salah satu lapisan.
  for layer in layerNames:
    if n.startsWith(layer & "/"):
      return layer
  ""

proc isCrossModuleInternal*(imp: string, ownModule: string,
                            modules: openArray[string] = knownModuleNames): bool =
  ## True bila import menembus internal **modul bisnis** lain (bukan lewat `/api`).
  ## Import ke paket pihak ketiga atau ke akar bersama (kernel/platform-lib) bukan pelanggaran.
  let n = normalizeImport(imp)
  if not n.contains('/'):
    return false
  let head = n.split('/')[0]
  if head == ownModule or head in knownRoots or head in layerNames:
    return false
  if head notin modules:
    return false
  let rest = n[head.len + 1 .. ^1]
  not rest.startsWith("api")

proc forbiddenForDomain(imp: string): bool =
  let n = normalizeImport(imp)
  ## `platform-lib` membungkus DB/HTTP/log: tidak ada urusan di domain yang murni.
  n.startsWith("platform-lib") or
    n.startsWith("db_connector") or n.startsWith("db_postgres") or
    n.startsWith("std/asyncdispatch") or n.startsWith("std/net") or
    n.startsWith("std/httpclient") or n.startsWith("std/osproc") or
    n.startsWith("std/os")

proc forbiddenForApplication(imp: string): bool =
  let n = normalizeImport(imp)
  ## Application boleh memakai `platform-lib/log` (cross-cutting), tetapi bukan pool DB/HTTP.
  n.startsWith("platform-lib/db") or
    n.startsWith("db_connector") or n.startsWith("db_postgres") or
    n.startsWith("std/httpclient")

proc isKernelForeignImport(imp: string): bool =
  let n = normalizeImport(imp)
  if n.startsWith("db_connector") or n.startsWith("db_postgres"):
    return true
  if not n.contains('/'):
    return false
  not (n.startsWith("std/") or n.startsWith("kernel/"))

proc touchesModuleInternal*(imp: string, ownModule: string,
                            modules: openArray[string]): bool =
  ## True bila import menunjuk `infrastructure`/`domain` sebuah modul bisnis.
  ## `ownModule` (bila tidak kosong) dikecualikan: test boleh memakai internal modulnya sendiri.
  let n = normalizeImport(imp)
  if not n.contains('/'):
    return false
  let head = n.split('/')[0]
  if head == ownModule or head notin modules:
    return false
  let rest = n[head.len + 1 .. ^1]
  rest.startsWith("infrastructure/") or rest.startsWith("domain/")

proc violation(path: string, line: int, rule, message: string, imp = ""): Violation =
  Violation(path: path, line: line, rule: rule, message: message, imp: imp)

proc scanSource*(relPath, source: string,
                 modules: openArray[string] = knownModuleNames): seq[Violation] =
  ## Pindai satu berkas. `relPath` relatif terhadap akar repo (mis. `modules/x/domain/y.nim`).
  let (category, module) = classify(relPath)
  if category == catSkip:
    return @[]
  let lines = source.splitLines()
  var idx = 0
  while idx < lines.len:
    var raw = lines[idx]
    let lineNo = idx + 1
    # Import bentuk bracket boleh terlipat: gabungkan sampai bracket seimbang supaya
    # import yang dilanggar terbaca utuh (kunci baseline tidak terpotong).
    var depth = bracketDepth(raw)
    while depth > 0 and idx + 1 < lines.len:
      inc idx
      let next = lines[idx].strip()
      raw.add " " & next
      depth += bracketDepth(next)
    inc idx
    let okPos = raw.find(hatch)
    if okPos >= 0:
      if raw[okPos + len(hatch) .. ^1].strip().len == 0:
        result.add violation(relPath, lineNo, "E",
          "escape hatch `" & hatch & "` tanpa alasan")
      continue
    for imp in importsOf(raw):
      let impKey = unquote(imp.strip())
      if category == catHandler:
        # Handler hanya lewat api/application modul; internal modul tidak.
        if touchesModuleInternal(imp, "", modules):
          result.add violation(relPath, lineNo, "F",
            "handler hanya lewat api/application modul, bukan internalnya: " & imp, impKey)
        continue
      if category == catTest:
        # Test boleh memakai internal modulnya sendiri, bukan internal modul lain.
        if touchesModuleInternal(imp, module, modules):
          result.add violation(relPath, lineNo, "G",
            "test tidak boleh memakai internal modul lain: " & imp, impKey)
        continue
      let within = stripOwnModule(normalizeImport(imp), module)
      let layer = layerOf(within)
      if category == catKernel:
        if isKernelForeignImport(imp):
          result.add violation(relPath, lineNo, "D",
            "kernel hanya boleh stdlib & sesama kernel: " & imp)
        continue
      if isCrossModuleInternal(imp, module, modules):
        result.add violation(relPath, lineNo, "C",
          "modul hanya lewat api.nim modul lain, bukan internalnya: " & imp)
        continue
      case category
      of catDomain:
        if layer in ["application", "infrastructure", "interface"]:
          result.add violation(relPath, lineNo, "A",
            "domain tidak boleh import lapisan " & layer & ": " & imp)
        elif forbiddenForDomain(imp):
          result.add violation(relPath, lineNo, "A",
            "domain harus murni (tanpa I/O/DB): " & imp)
      of catApplication:
        if layer in ["infrastructure", "interface"]:
          result.add violation(relPath, lineNo, "B",
            "application tidak boleh menyentuh " & layer & ": " & imp)
        elif forbiddenForApplication(imp):
          result.add violation(relPath, lineNo, "B",
            "application harus bicara ke port, bukan driver DB: " & imp)
      else:
        discard

proc moduleNamesUnder*(root: string): seq[string] =
  ## Nama modul nyata dari `modules/` — dipakai supaya aturan C tidak menebak dari daftar.
  let dir = root / "modules"
  if dirExists(dir):
    for kind, path in walkDir(dir):
      if kind in {pcDir, pcLinkToDir}:
        result.add extractFilename(path)
  result.sort()

proc scanRoot*(root: string): seq[Violation] =
  ## Telusuri `root` dan pindai semua berkas `.nim` yang relevan.
  let skipDirs = [".git", ".build", "node_modules", ".local", "nimcache"]
  let modules = moduleNamesUnder(root)
  for path in walkDirRec(root, yieldFilter = {pcFile}):
    let rel = relativePath(path, root).replace('\\', '/')
    var skip = false
    for d in skipDirs:
      if rel.startsWith(d & "/") or rel.contains("/" & d & "/"):
        skip = true
        break
    if skip or not rel.endsWith(".nim"):
      continue
    if classify(rel).category == catSkip:
      continue
    var source = ""
    try:
      source = readFile(path)
    except CatchableError:
      continue
    result.add scanSource(rel, source, modules)

proc formatViolation*(v: Violation): string =
  v.path & ":" & $v.line & ": [" & v.rule & "] " & v.message

proc baselineKey*(v: Violation): string =
  ## Kunci baseline sengaja tanpa nomor baris: baris bergeser tiap edit, pelanggaran tidak.
  v.rule & "|" & v.path & "|" & v.imp

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
  ## Tiga hasil: cocok, pelanggaran baru (gagal), entri basi (gagal, baseline harus menyusut).
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
  result = "# archcheck baseline — pelanggaran batas yang diterima apa adanya. HANYA BOLEH MENYUSUT.\n"
  result.add "# format: rule|path|import. Hapus satu baris saat pelanggarannya diperbaiki.\n"
  for k in sorted:
    result.add k & "\n"
