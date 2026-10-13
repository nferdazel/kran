## Logika `tools/scaffold` (spec §5.5, §27.B).
##
## Menghasilkan kerangka modul baru di `modules/<nama>/` mengikuti struktur spec §7:
## domain/application/infrastructure/interface + migrasi + test + seed parameter + README +
## `MODULE.md` + `api.nim`.
##
## Kode yang dihasilkan sengaja tanpa nilai bisnis dan lolos `tools/archcheck` &
## `tools/lint-nomagic` apa adanya. Berkas internal memakai nama peran (`core.nim`,
## `use_case.nim`) supaya modul dengan tanda hubung pun tetap menghasilkan Nim yang sah
## (Nim menolak `-` di nama modul/berkas).
##
## Murni: `renderModule` tidak menyentuh disk; `writeModule` yang menulis.

import std/[os, strutils]

type
  ScaffoldError* = object of ValueError

  ScaffoldFile* = object
    path*: string ## relatif terhadap akar repo, mis. `modules/hello/api.nim`
    content*: string

const
  nameHint* = "huruf kecil, angka, atau tanda hubung; harus diawali huruf"
  ## Penanda di template yang diganti saat render. `@` tidak sah di nama modul, jadi
  ## tidak mungkin bentrok dengan isi.
  tokenName = "@name@"
  tokenSanitized = "@sanitized@"
  tokenSchema = "@schema@"

proc fail(msg: string) {.noreturn.} =
  raise newException(ScaffoldError, msg)

proc isValidModuleName*(name: string): bool =
  ## Pola `[a-z][a-z0-9-]*` (BACKLOG T-011). `.` dan `/` tidak termasuk → tidak ada jalan
  ## untuk path traversal lewat nama modul.
  if name.len == 0 or name[0] notin {'a' .. 'z'}:
    return false
  for c in name:
    if c notin {'a' .. 'z', '0' .. '9', '-'}:
      return false
  true

proc sanitizedModuleName*(name: string): string =
  ## Nama aman untuk berkas & modul Nim: `-` → `_`.
  name.replace('-', '_')

proc moduleDir*(root, name: string): string =
  root / "modules" / name

const
  readmeMd = """# Modul `@name@`

Kerangka awal hasil `./task scaffold @name@` (spec §5.5).

- Tujuan, bounded context, tabel, dan invarian: `MODULE.md`.
- Permukaan publik modul: `api.nim`.
- Mulai mengisi dari `domain/core.nim` lalu `application/use_case.nim`.

Setelah diisi, jaga modul ini tetap hijau dengan `./task check` (archcheck + lint-nomagic).
"""

  moduleMd = """# Modul `@name@`

> Kerangka hasil `./task scaffold @name@` (spec §5.5). Ganti isi placeholder ini saat modul
> diisi; jangan biarkan tetap seperti ini di modul yang sudah dipakai.

## Tujuan & Bounded Context

TODO: satu paragraf — apa yang dimiliki modul ini dan (tak kalah penting) yang bukan.
Bounded context lain hanya berbicara lewat `api.nim` dan kontrak event (spec §6.3).

## Aggregate & Aturan Bisnis Utama

- Belum ada aggregate; `domain/core.nim` masih contoh fungsi murni.
- Aturan bisnis wajib param-driven, bukan konstanta di kode (spec §10, AGENTS.md §1.2).

## Public API (api.nim)

- `greet(who: string): string` — contoh; ganti dengan permukaan publik sesungguhnya.
- `greetUser(who: string): string` — contoh use case.

## Event dipublish / dikonsumsi (versi)

- Belum ada. Nama event `PascalCase` lampau, versi `v1`, kontrak di
  `packages/contracts/events` (spec §12.4).

## Parameter key (+ sensitivitas, regulatory_refs)

- Belum ada; `seeds/params.yaml` masih daftar kosong.
- Pola key: `@name@.kategori.nama` (spec §27.A). Nilai default pack lewat `paramgen`
  (spec §10.3); nilai bisnis tidak boleh di kode.

## Tabel & schema

- Schema Postgres `@name@` dibuat `migrations/0001_@name@_init.sql`.
- Tabel: belum ada.

## Task day-close yang didaftarkan

- Belum ada. Day-close hanya lewat framework `daycloser` (AGENTS.md §1.7); modul tidak
  membuat batch/cron sendiri.

## Permission

- Belum ada. Pola: `@name@.<resource>.<action>` (spec §27.A).

## Namespace i18n

- Belum ada. Pakai prefix `@name@.` saat katalog i18n dibangun (T-010, spec §5.5).

## Requirement regulasi terkait (REG-xxx → test)

- Tidak ada. Jangan mengarang nomor pasal (spec §1.8); tambahkan setelah diverifikasi
  compliance owner, lengkap dengan test-nya.

## Keputusan & trade-off (link ADR)

- Belum ada.

## Menjalankan test

- `./task test t@sanitized@` — unit test modul ini (tanpa DB).
- `./task check` — archcheck + lint-nomagic + paramgen --check.
- `./task dbtools validate` — validasi migrasi (expand-only).
"""

  apiNim = """## Permukaan publik modul `@name@` (spec §5.5).
##
## Modul lain hanya boleh berbicara lewat berkas ini, bukan import internalnya
## (dijaga `tools/archcheck`).

import ./domain/core
import ./application/use_case

export core, use_case
"""

  domainCore = """## Domain murni modul `@name@` (spec §5.5).
##
## Ganti berkas contoh ini dengan entity/value object/domain service sesungguhnya.
## Lapisan ini murni: tanpa I/O, DB, atau import internal modul lain — dijaga
## `tools/archcheck`.

proc greet*(who: string): string =
  ## Contoh fungsi murni; tanpa nilai bisnis apa pun (spec §10.4).
  "Halo, " & who & "!"
"""

  applicationUseCase = """## Lapisan application modul `@name@` (spec §7): use case + port.
##
## Boleh tahu domain modul ini dan port yang didefinisikan di sini; TIDAK boleh menyentuh
## driver DB/HTTP (dijaga `tools/archcheck`).

import ../domain/core

proc greetUser*(who: string): string =
  ## Contoh use case: memanggil domain. Ganti dengan use case sesungguhnya.
  greet(who)
"""

  infrastructurePlaceholder = """## Lapisan infrastructure modul `@name@` (spec §7): repository PG/adapter.
##
## Belum ada adapter. Semua I/O (DB, jaringan) tinggal di lapisan ini — bukan di
## domain/application (dijaga `tools/archcheck`). Isi berkas ini saat repo pertama dibuat.
"""

  interfacePlaceholder = """## Lapisan interface modul `@name@` (spec §7): HTTP handler/DTO/registrasi route.
##
## Belum ada konsumen HTTP; isi berkas ini setelah server dipilih (spesifikasi ADR-002).
"""

  testModule = """import std/unittest

import ../api

suite "modul @name@ (scaffold)":
  test "greet menyapa":
    check greet("Dunia") == "Halo, Dunia!"

  test "use case memanggil domain":
    check greetUser("Dunia") == "Halo, Dunia!"
"""

  migrationSql = """-- Migrasi awal modul `@name@` (spec §9.1(11): expand-only).
--
-- Satu modul = satu schema Postgres (spec §6.3). Tabel ditambahkan lewat migrasi bernomor
-- lebih besar; perubahan destruktif butuh header `-- dbtools:destructive <alasan>` dan
-- keputusan terpisah.
CREATE SCHEMA IF NOT EXISTS @schema@;
"""

  paramsYaml = """# Definisi parameter modul `@name@` (spec §10.3).
#
# Belum ada parameter. Tambahkan di sini, lalu jalankan `./task paramgen-gen` supaya
# konstanta bertipe ikut ter-regenerate. Nilai bisnis tidak boleh ditulis di kode
# (spec §10.4, dijaga `tools/lint-nomagic`).
[]
"""

proc applyTokens(s, name, sanitized, schema: string): string =
  result = s.replace(tokenName, name)
  result = result.replace(tokenSanitized, sanitized)
  result = result.replace(tokenSchema, schema)

proc renderModule*(name: string): seq[ScaffoldFile] =
  ## Berkas modul `name` (relatif akar repo). Murni: tidak menyentuh disk.
  if not isValidModuleName(name):
    fail("nama modul tidak sah: `" & name & "` (" & nameHint & ")")
  let sanitized = sanitizedModuleName(name)
  ## Schema Postgres dikutip hanya bila perlu: `-` bukan karakter identifier SQL tanpa kutip.
  let schema = if name.contains('-'): "\"" & name & "\"" else: name

  proc mk(path, content: string): ScaffoldFile =
    ScaffoldFile(path: path, content: applyTokens(content, name, sanitized, schema))

  let base = "modules/" & name
  result = @[
    mk(base & "/README.md", readmeMd),
    mk(base & "/MODULE.md", moduleMd),
    mk(base & "/api.nim", apiNim),
    mk(base & "/domain/core.nim", domainCore),
    mk(base & "/application/use_case.nim", applicationUseCase),
    mk(base & "/infrastructure/placeholder.nim", infrastructurePlaceholder),
    mk(base & "/interface/placeholder.nim", interfacePlaceholder),
    mk(base & "/migrations/0001_" & name & "_init.sql", migrationSql),
    mk(base & "/seeds/params.yaml", paramsYaml),
    mk(base & "/tests/t" & sanitized & ".nim", testModule),
  ]

proc writeModule*(root, name: string, dryRun = false): seq[string] =
  ## Menulis kerangka modul ke `root/modules/<name>/`.
  ##
  ## Raise `ScaffoldError` bila nama tidak sah atau modul sudah ada (tidak menimpa berkas
  ## milik manusia). `dryRun` hanya mengembalikan daftar berkas tanpa menulis.
  let files = renderModule(name)
  if dirExists(moduleDir(root, name)):
    fail("modul sudah ada, tidak ditimpa: modules/" & name)
  if dryRun:
    for f in files:
      result.add f.path
    return
  for f in files:
    let full = root / f.path
    createDir(parentDir(full))
    writeFile(full, f.content)
    result.add f.path
