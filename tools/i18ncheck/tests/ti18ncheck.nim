import std/[os, strutils, unittest]

import ../lib

## Test `tools/i18ncheck` (spec §16.3). Pohon repo palsu dibuat di direktori sementara supaya
## tiap kasus (katalog lengkap, key hilang, placeholder beda, key yatim) bisa diuji terpisah.

proc writeFileWithDirs(path, content: string) =
  createDir(path.parentDir)
  writeFile(path, content)

proc makeRepo(caseName: string): string =
  ## Membuat kerangka `packages/i18n/messages` + `apps/web/src` yang minimal.
  result = getTempDir() / ("i18ncheck-" & caseName)
  if dirExists(result):
    removeDir(result)
  createDir(result / "packages/i18n/messages")
  createDir(result / "apps/web/src")

proc hasProblem(problems: seq[string], needle: string): bool =
  for p in problems:
    if needle in p:
      return true
  false

proc hasProblem(report: CheckReport, needle: string): bool =
  hasProblem(report.problems, needle)

suite "placeholders (ICU)":
  test "argumen sederhana & plural dikenali":
    check placeholders("Halo {nama}") == @["nama"]
    check placeholders("{count} rekening") == @["count"]
    check placeholders("Nilai {amount, number} untuk {who}") == @["amount", "who"]

  test "urutan stabil dan duplikat dibuang":
    check placeholders("{b} dan {a} dan {b}") == @["a", "b"]

  test "teks tanpa placeholder = kosong":
    check placeholders("Belum ada rekening").len == 0

suite "validKeyShape":
  test "namespace_key wajib minimal dua segmen":
    check validKeyShape("common_app_title")
    check validKeyShape("deposit_account_open_title")

  test "bentuk salah ditolak":
    check not validKeyShape("title")
    check not validKeyShape("Common_App_Title")
    check not validKeyShape("common..title")
    check not validKeyShape("common_app_")

suite "messageCallsIn (pemakaian key di kode)":
  test "bentuk m.<key>( dan messages.<key>( dikenali":
    check messageCallsIn("const a = m.common_app_title();") == @["common_app_title"]
    check messageCallsIn("messages.common_nav_home()") == @["common_nav_home"]

  test "identifier lain tidak dianggap key pesan":
    check messageCallsIn("media.addEventListener('x', y);").len == 0
    check messageCallsIn("const m = obj.m.join(',');").len == 0

  test "properti yang diakhiri titik bukan pemanggilan pesan kecuali diikuti tanda kurung":
    check messageCallsIn("const x = m.common_app_title;").len == 0
    check messageCallsIn("const x = m.common_app_title ()").len == 1

suite "checkCatalogs":
  test "katalog lengkap & dipakai kode = tanpa temuan":
    let root = makeRepo("bersih")
    writeFileWithDirs(root / "packages/i18n/messages/id.json",
      """{ "common_app_title": "CBS", "common_greet": "Halo {nama}" }""")
    writeFileWithDirs(root / "packages/i18n/messages/en.json",
      """{ "common_app_title": "CBS", "common_greet": "Hello {nama}" }""")
    writeFileWithDirs(root / "apps/web/src/page.svelte",
      "{m.common_app_title()}\n{m.common_greet({ nama: 'x' })}")

    let report = checkCatalogs(root)
    check report.problems.len == 0
    check report.keyCount == 2

  test "key hanya ada di satu locale = temuan":
    let root = makeRepo("key-hilang")
    writeFileWithDirs(root / "packages/i18n/messages/id.json",
      """{ "common_app_title": "CBS", "common_only_id": "Hanya di id" }""")
    writeFileWithDirs(root / "packages/i18n/messages/en.json",
      """{ "common_app_title": "CBS" }""")
    writeFileWithDirs(root / "apps/web/src/page.svelte",
      "{m.common_app_title()}{m.common_only_id()}")

    let report = checkCatalogs(root)
    check report.hasProblem("common_only_id' hilang")

  test "placeholder berbeda antar-locale = temuan":
    let root = makeRepo("placeholder")
    writeFileWithDirs(root / "packages/i18n/messages/id.json",
      """{ "common_greet": "Halo {nama}" }""")
    writeFileWithDirs(root / "packages/i18n/messages/en.json",
      """{ "common_greet": "Hello {name}" }""")
    writeFileWithDirs(root / "apps/web/src/page.svelte", "{m.common_greet({})}")

    check checkCatalogs(root).hasProblem("placeholder")

  test "key yatim (tidak dipakai kode) = temuan":
    let root = makeRepo("yatim")
    writeFileWithDirs(root / "packages/i18n/messages/id.json",
      """{ "common_used": "Dipakai", "common_unused": "Tidak" }""")
    writeFileWithDirs(root / "packages/i18n/messages/en.json",
      """{ "common_used": "Used", "common_unused": "Never" }""")
    writeFileWithDirs(root / "apps/web/src/page.svelte", "{m.common_used()}")

    check checkCatalogs(root).hasProblem("common_unused' tidak dipakai")

  test "kode memakai key yang tidak ada di katalog = temuan":
    let root = makeRepo("key-asing")
    writeFileWithDirs(root / "packages/i18n/messages/id.json", """{ "common_a": "A" }""")
    writeFileWithDirs(root / "packages/i18n/messages/en.json", """{ "common_a": "A" }""")
    writeFileWithDirs(root / "apps/web/src/page.svelte", "{m.common_belum_ada()}")

    check checkCatalogs(root).hasProblem("common_belum_ada")

  test "kode hasil generate tidak dipindai (m.join/m.push bukan key)":
    let root = makeRepo("generated")
    writeFileWithDirs(root / "packages/i18n/messages/id.json", """{ "common_a": "A" }""")
    writeFileWithDirs(root / "packages/i18n/messages/en.json", """{ "common_a": "A" }""")
    writeFileWithDirs(root / "apps/web/src/page.svelte", "{m.common_a()}")
    writeFileWithDirs(root / "apps/web/src/lib/paraglide/runtime.js",
      "const x = m.join(','); const y = m.push(1);")

    check checkCatalogs(root).problems.len == 0

  test "key tanpa bentuk namespace = temuan":
    let root = makeRepo("bentuk")
    writeFileWithDirs(root / "packages/i18n/messages/id.json", """{ "title": "Judul" }""")
    writeFileWithDirs(root / "packages/i18n/messages/en.json", """{ "title": "Title" }""")
    writeFileWithDirs(root / "apps/web/src/page.svelte", "{m.title()}")

    check checkCatalogs(root).hasProblem("tidak berbentuk namespace_key")

  test "nilai pesan bukan string = temuan, bukan crash":
    let root = makeRepo("bukan-string")
    writeFileWithDirs(root / "packages/i18n/messages/id.json", """{ "common_a": { "nested": "x" } }""")
    writeFileWithDirs(root / "packages/i18n/messages/en.json", """{ "common_a": "A" }""")

    let report = checkCatalogs(root)
    check report.hasProblem("pesan harus string")

  test "json rusak = temuan, bukan crash":
    let root = makeRepo("json-rusak")
    writeFileWithDirs(root / "packages/i18n/messages/id.json", "{ bukan json")
    writeFileWithDirs(root / "packages/i18n/messages/en.json", """{ "common_a": "A" }""")

    check checkCatalogs(root).hasProblem("tidak terbaca")

  test "direktori katalog tidak ada = temuan":
    let root = makeRepo("tanpa-katalog")
    removeDir(root / "packages/i18n/messages")

    check checkCatalogs(root).hasProblem("direktori katalog tidak ada")

suite "renderReport":
  test "ringkas dan menyebut jumlah locale/key":
    let root = makeRepo("laporan")
    writeFileWithDirs(root / "packages/i18n/messages/id.json", """{ "common_a": "A" }""")
    writeFileWithDirs(root / "packages/i18n/messages/en.json", """{ "common_a": "A" }""")
    writeFileWithDirs(root / "apps/web/src/page.svelte", "{m.common_a()}")

    let report = checkCatalogs(root)
    let text = renderReport(report)
    check "2 locale, 1 key/locale" in text
    check "tidak ada temuan" in text
