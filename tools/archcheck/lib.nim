## Logika penegak batas arsitektur (spec §5.1, §6.3). Murni: bisa diuji tanpa spawn proses.
##
## Model yang dipakai (arah dependensi ke dalam):
##   - `domain` boleh import: stdlib murni, `kernel`, sesama berkas domain modulnya sendiri.
##   - `application` boleh import: domain modulnya sendiri, stdlib (kecuali driver), `kernel`.
##   - `infrastructure`/`interface` mengimplementasikan port; boleh import lebih bebas,
##     tetapi tetap tidak boleh menembus **internal modul lain**.
##   - Modul hanya bicara lewat `api.nim` modul lain (spec §5.5).
##   - `shared/kernel` hanya stdlib & sesama kernel.
##
## Escape hatch: `# archcheck:ok <alasan-obligatoris>` pada baris import yang sama.

import std/[strutils, os, algorithm]

type
  Category* = enum
    catSkip
    catDomain
    catApplication
    catInfrastructure
    catInterface
    catModuleApi
    catKernel

  Violation* = object
    path*: string
    line*: int
    rule*: string ## "A" (domain) | "B" (application) | "C" (batas modul) | "D" (kernel) | "E" (escape hatch)
    message*: string

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
  if r.startsWith("tools/") or r.contains("/tests/") or r.contains("/generated/"):
    return (catSkip, "")
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
  var items: seq[string]
  if body.contains(','):
    items = body.split(',')
  else:
    items = @[body]
  for raw in items:
    let item = raw.strip()
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

proc violation(path: string, line: int, rule, message: string): Violation =
  Violation(path: path, line: line, rule: rule, message: message)

proc scanSource*(relPath, source: string,
                 modules: openArray[string] = knownModuleNames): seq[Violation] =
  ## Pindai satu berkas. `relPath` relatif terhadap akar repo (mis. `modules/x/domain/y.nim`).
  let (category, module) = classify(relPath)
  if category == catSkip:
    return @[]
  for idx, raw in source.splitLines().pairs():
    let lineNo = idx + 1
    let okPos = raw.find(hatch)
    if okPos >= 0:
      if raw[okPos + len(hatch) .. ^1].strip().len == 0:
        result.add violation(relPath, lineNo, "E",
          "escape hatch `" & hatch & "` tanpa alasan")
      continue
    for imp in importsOf(raw):
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
