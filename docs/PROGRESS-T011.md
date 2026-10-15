# PROGRESS T-011 — `tools/scaffold` + modul contoh `hello`

Log kerja T-011. Dikerjakan di worktree terpisah
(`~/.local/share/opencode/worktree/13c36f/t-011-scaffold`, HEAD detached) — **bukan** di repo
utama. Tidak ada push/merge/pindah branch. DB dev tidak tersedia di worktree ini.

Rencana + keputusan desain: `docs/tasks/T-011.md`.

---

## 1. Berkas dibuat / diubah

| Berkas | Isi ringkas |
|---|---|
| `tools/scaffold/lib.nim` | Logika murni: `isValidModuleName` (`[a-z][a-z0-9-]*`), `sanitizedModuleName`, `renderModule` (10 berkas), `writeModule` (tolak timpa + `dryRun`). |
| `tools/scaffold/main.nim` | CLI `scaffold [--root <dir>] [--dry-run] <nama>`; exit 0/1/2. |
| `tools/scaffold/tests/tscaffold.nim` | 13 test: validasi nama, isi/render, tulis ke `$TMPDIR`, tolak timpa, dry-run, output lolos `scanSource` archcheck. |
| `modules/hello/**` | **Hasil generate tool itu sendiri** (`./task scaffold hello`): 10 berkas (README.md, MODULE.md, api.nim, domain/core.nim, application/use_case.nim, infrastructure/placeholder.nim, interface/placeholder.nim, migrations/0001_hello_init.sql, seeds/params.yaml, tests/thello.nim). |
| `task` | +9 baris: dokumentasi header, fungsi `cmd_scaffold`, satu `case scaffold`. Tidak ada bagian lain yang disentuh. |
| `docs/tasks/T-011.md`, `docs/PROGRESS-T011.md` | Laporan ini. |

Commit: lihat §6.

## 2. Perintah verifikasi + keluaran

### 2.1 `./task check` (hijau)

```
== format (nimpretty)              ok: 61 berkas
== lint (nim check)                ok: 62 berkas
== archcheck                       archcheck: tidak ada pelanggaran batas arsitektur
                                   ok: batas modul bersih
== lint-nomagic                    lint-nomagic: tidak ada magic number bisnis di domain/application
== paramgen --check                paramgen: sinkron (2 berkas seeds/params.yaml)
== i18n check                      SKIP: packages/i18n/messages belum ada (T-010)
== shell sintaks skrip ops         ok: 7 skrip lolos bash -n (shellcheck tidak ada di PATH)
```

### 2.2 `./task test` (hijau; integrasi SKIP)

```
== unit + property test            semua suite lulus (lihat daftar test §2.4)
== integration test (Postgres)     SKIP: KRAN_DATABASE_URL kosong
== contract test                   SKIP: packages/contracts/openapi belum ada (T-008)
```

### 2.3 `./task ci` (hijau)

```
CI_EXIT=0
...
== CI hijau
```

Log penuh: `.build/ci-t011.log` (gitignored).

### 2.4 Test file yang dikompilasi & dijalankan

```
modules/hello/tests/thello.nim            <-- modul hasil scaffold (BARU)
tools/scaffold/tests/tscaffold.nim        <-- test tool (BARU)
tools/archcheck/tests/tarchcheck.nim
tools/dbtools/tests/tdbtools.nim
tools/lint-nomagic/tests/tnomagic.nim
tools/paramgen/tests/tparamgen.nim
modules/platform/tests/tcalendar.nim
modules/platform/tests/tparam.nim
shared/kernel/tests/{tauditcontext,tbusinessdate,tclock,tids,tmoney,tprop_money,tprop_rate,trate,tresult}.nim
shared/platform-lib/tests/{tconfig,tlog}.nim
```

`hello` suite: `greet` + `greetUser` lulus; `tscaffold` 13/13 lulus.

### 2.5 archcheck benar-benar memeriksa modul `hello`

`./task archcheck` atas repo → `tidak ada pelanggaran batas arsitektur` (exit 0). Untuk
membuktikan tool tidak sekadar diam, hello di-generate ke root temporer lalu diuji dua kali:

```
$ .build/bin/archcheck "$T"        # root hanya berisi modules/hello
archcheck: tidak ada pelanggaran batas arsitektur        (exit 0)

$ printf 'import std/os\n' >> "$T/modules/hello/domain/core.nim"
$ .build/bin/archcheck "$T"
archcheck: 1 pelanggaran
  modules/hello/domain/core.nim:11: [A] domain harus murni (tanpa I/O/DB): std/os
                                                          (exit 1)
```

### 2.6 Penolakan argumen CLI

```
$ ./task scaffold Hello
scaffold: nama modul tidak sah: `Hello` (huruf kecil, angka, atau tanda hubung; harus diawali huruf)   exit 1
$ ./task scaffold hello
scaffold: modul sudah ada, tidak ditimpa: modules/hello                                                 exit 1
$ ./task scaffold ../evil
scaffold: nama modul tidak sah: `../evil` (...)                                                          exit 1
```

### 2.7 Template == berkas di disk

`./task fmt` dijalankan pada hasil generate; `diff -r` antara hasil generate baru (tanpa fmt)
dan `modules/hello` di disk → **identik**, jadi template sudah nimpretty-clean apa adanya.

## 3. Yang TIDAK bisa diverifikasi (jujur)

- **Test integrasi (Postgres) tidak dijalankan** — `KRAN_DATABASE_URL` kosong di worktree ini;
  `itplatform`/`itcalendar`/`itpool` SKIP. Tidak ada DB dibuat (sesuai instruksi).
- **e2e Playwright tidak dijalankan** — `apps/web` belum ada (T-010).
- **Kompilasi modul ber-tanda-hubung tidak dijadikan test otomatis.** Dicoba manual (probe) dan
  lolos dengan template ini, tetapi test hanya memverifikasi penamaan test tersanitasi.
- **i18n namespace belum ada** — menunggu T-010 (lihat keputusan 5 di T-011.md).
- **`hello` bukan modul bisnis**: isinya contoh; tidak ada perilaku bisnis yang perlu diuji.

## 4. Ketidakpastian / catatan

1. **Pola nama `[a-z][a-z0-9-]*` vs identifier Nim.** Implementasi mengikuti regex BACKLOG
   (boleh `-`) dan mengakali keterbatasan Nim lewat nama berkas peran + sanitasi nama test.
   Bila pemilik menginginkan spec §27.A `snake_case` murni (`[a-z][a-z0-9_]*`), regex itu bisa
   diperketat tanpa mengubah struktur keluaran.
2. **`MODULE.md` template mengandung TODO** yang memang harus diisi manusia; ini bukan
   "placeholder kosong" (semua bagian §27.B terisi + ada cara menjalankan test).
3. **`--dry-run` pada modul yang sudah ada tetap menolak** (cek "sudah ada" sebelum cek
   dry-run). Dianggap wajar: dry-run memberi tahu operasi akan ditolak.

## 5. Sisa pekerjaan / turunan

- Tambahkan namespace i18n saat T-010 ada (`packages/i18n`), lalu regenerasi `hello`.
- Pertimbangkan test otomatis yang mengompilasi modul hasil scaffold (butuh pemanggilan `nim`
  dari test) agar jaminan "hijau" tidak bergantung pada `hello` yang di-commit.

## 6. Commit

<!-- HASH-COMMIT -->
