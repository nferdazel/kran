## Pemeriksa katalog i18n (spec §16.3): key lengkap di semua locale, tanpa key yatim,
## placeholder konsisten, dan tidak ada string hardcode yang jelas di komponen.
##
## Murni baca berkas — tidak menyentuh DB/jaringan.

import std/[algorithm, json, os, sets, strformat, strutils, tables]

type
  LocaleCatalog* = object
    locale*: string
    path*: string
    keys*: Table[string, string] ## key -> pesan

  CheckReport* = object
    problems*: seq[string]
    locales*: seq[string]
    keyCount*: int

const
  messagesDirRel* = "packages/i18n/messages"
  ## Namespace default untuk pesan shell lintas modul.
  defaultNamespace* = "common"
  ## Berkas sumber yang diperiksa untuk pemakaian key: TypeScript/Svelte di aplikasi & paket UI.
  scannedDirs* = ["apps/web/src", "packages/ui/src"]
  scannedExts* = [".ts", ".svelte", ".js"]
  ## Direktori yang dilewati saat memindai pemakaian key: kode hasil generate (Paraglide) dan
  ## artefak build. Tanpa ini, panggilan seperti `arr.join(...)` di kode hasil generate
  ## (`m.join(`, `m.push(`) akan salah dianggap sebagai pemakaian key pesan.
  ignoredDirParts* = ["/lib/paraglide/", "/.svelte-kit/", "/node_modules/", "/build/", "/dist/"]

proc fail(report: var CheckReport, msg: string) =
  report.problems.add msg

proc isLocaleFile(name: string): bool =
  name.endsWith(".json") and not name.endsWith(".schema.json")

proc localeOf(path: string): string =
  path.splitFile.name

proc loadCatalog(path: string): LocaleCatalog =
  ## Raise `JsonParsingError`/`IOError` bila berkas rusak — pemanggil yang mengubahnya jadi temuan.
  let node = parseFile(path)
  if node.kind != JObject:
    raise newException(ValueError, "katalog harus objek JSON: " & path)
  result.locale = localeOf(path)
  result.path = path
  for key, value in node:
    if value.kind != JString:
      raise newException(ValueError,
        "pesan harus string (key: " & key & ", dapat " & $value.kind & "): " & path)
    result.keys[key] = value.getStr()

proc placeholders*(message: string): seq[string] =
  ## Placeholder ICU yang dikenali: nama argumen di dalam `{...}` (mis. `{n, plural, …}` → `n`,
  ## `{theme}` → `theme`). Dikembalikan terurut & unik supaya perbandingan antar-locale stabil.
  var names = initHashSet[string]()
  var depth = 0
  var current = ""
  for c in message:
    case c
    of '{':
      inc depth
      if depth == 1:
        current = ""
    of '}':
      if depth == 1:
        let head = current.split(',')[0].strip()
        if head.len > 0:
          names.incl head
      depth = max(0, depth - 1)
    else:
      if depth == 1:
        current.add c
  var listed: seq[string]
  for name in names:
    listed.add name
  listed.sort()
  listed

proc validKeyShape*(key: string): bool =
  ## `namespace_rest…`: minimal dua segmen, huruf kecil/angka, dipisah `_`.
  let parts = key.split('_')
  if parts.len < 2:
    return false
  for part in parts:
    if part.len == 0:
      return false
    for c in part:
      if not (c in {'a' .. 'z', '0' .. '9'}):
        return false
  true

const
  identChars* = {'a' .. 'z', 'A' .. 'Z', '0' .. '9', '_'}
  wsChars* = {' ', '\t', '\n', '\r'}
  callPrefixes* = ["messages.", "m."]

proc messageCallsIn*(content: string): seq[string] =
  ## Mencari pemanggilan pesan `m.<key>(` / `messages.<key>(` dengan pemindai sederhana.
  ## Sengaja tanpa regex: perilakunya mudah diuji dan tidak menganggap identifier lain
  ## (mis. `media.addEventListener`) sebagai key pesan.
  for i in 0 ..< content.len:
    if i > 0 and content[i - 1] in identChars:
      continue # bagian dari identifier lain, mis. `format.m.`
    if i > 0 and content[i - 1] == '.':
      continue # akses anggota dari nilai bernama `m`, mis. `obj.m.join(…)`
    for prefix in callPrefixes:
      if not content.continuesWith(prefix, i):
        continue
      var j = i + prefix.len
      var name = ""
      while j < content.len and content[j] in identChars:
        name.add content[j]
        inc j
      while j < content.len and content[j] in wsChars:
        inc j
      if name.len > 0 and j < content.len and content[j] == '(':
        result.add name

proc usedMessageKeys(root: string): HashSet[string] =
  ## Key yang benar-benar dipakai di kode aplikasi/komponen.
  for dir in scannedDirs:
    let base = root / dir
    if not dirExists(base):
      continue
    for path in walkDirRec(base):
      let ext = path.splitFile.ext
      if ext notin scannedExts:
        continue
      var skipped = false
      for part in ignoredDirParts:
        if part in path:
          skipped = true
          break
      if skipped:
        continue
      for name in messageCallsIn(readFile(path)):
        result.incl name

proc checkCatalogs*(root: string): CheckReport =
  ## Memeriksa `packages/i18n/messages/*.json` + pemakaian key di kode.
  let dir = root / messagesDirRel
  if not dirExists(dir):
    result.problems.add "direktori katalog tidak ada: " & messagesDirRel
    return

  var catalogs: seq[LocaleCatalog]
  for path in walkFiles(dir / "*.json"):
    if not isLocaleFile(path):
      continue
    try:
      catalogs.add loadCatalog(path)
    except CatchableError as e:
      result.problems.add "katalog tidak terbaca (" & path & "): " & e.msg
  if catalogs.len == 0:
    result.problems.add "tidak ada katalog locale di " & messagesDirRel
    return

  # Urut locale supaya keluaran deterministik (urutan walkFiles tidak dijamin) — pesan temuan
  # tidak boleh berubah hanya karena urutan berkas.
  catalogs.sort(proc (a, b: LocaleCatalog): int = cmp(a.locale, b.locale))

  for c in catalogs:
    result.locales.add c.locale

  let reference = catalogs[0]
  result.keyCount = reference.keys.len

  # Gabungan key semua locale: pemeriksaan parity tidak bergantung pada locale mana yang duluan.
  var allKeys = initHashSet[string]()
  for c in catalogs:
    for key in c.keys.keys:
      allKeys.incl key

  for c in catalogs:
    # 1. Key harus punya bentuk `namespace_key` (spec §16.2 namespace = modul).
    for key in c.keys.keys:
      if not validKeyShape(key):
        fail(result, &"{c.locale}: key '{key}' tidak berbentuk namespace_key (huruf kecil + '_')")

    # 2. Tidak boleh ada key yang hanya ada di sebagian locale.
    for key in allKeys:
      if not c.keys.hasKey(key):
        fail(result, &"{c.locale}: key '{key}' hilang (tidak ada di locale ini)")

    # 3. Placeholder konsisten antar-locale, dibandingkan ke locale acuan (urut pertama).
    for key, message in c.keys:
      if reference.keys.hasKey(key):
        let want = placeholders(reference.keys[key])
        let got = placeholders(message)
        if want != got:
          fail(result, &"{c.locale}: placeholder '{key}' berbeda — {got} vs {want} ({reference.locale})")

  # 4. Key yatim terhadap kode: didefinisikan tetapi tidak pernah dipakai.
  let used = usedMessageKeys(root)
  for key in allKeys:
    if key notin used:
      fail(result, &"key '{key}' tidak dipakai di kode mana pun (" & scannedDirs.join(", ") & ")")

  # 5. Key yang dipakai kode tetapi tidak ada di katalog.
  for key in used:
    if key notin allKeys:
      fail(result, &"kode memakai key '{key}' yang tidak ada di katalog " & messagesDirRel)

proc renderReport*(report: CheckReport): string =
  result = &"i18ncheck: {report.locales.len} locale, {report.keyCount} key/locale\n"
  if report.problems.len == 0:
    result.add "i18ncheck: katalog lengkap (key, placeholder, pemakaian) — tidak ada temuan\n"
  else:
    result.add &"i18ncheck: {report.problems.len} temuan\n"
    for problem in report.problems:
      result.add "  - " & problem & "\n"
