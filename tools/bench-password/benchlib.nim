## Parsing argumen + angka turunan `bench-password` (T-060).
##
## Dipisah dari `main.nim` supaya bisa diuji tanpa menjalankan benchmark (PBKDF2 600.000 iterasi).
## Kesalahan pemakaian melempar `UsageError` — bukan `quit()` di tengah — sehingga `main` yang
## menerjemahkannya menjadi kode keluar 2 dan test bisa memeriksa pesannya.

import std/strutils

const
  ## Default CLI saja; nilai kebijakan tetap datang dari `--iterations`/`--history-count`.
  defaultHistoryCount* = 5
  defaultReps* = 3

type
  Options* = object
    iterations*: int
    historyCount*: int
    reps*: int
    help*: bool

  UsageError* = object of CatchableError

proc parseIntArg(name, value: string): int =
  try:
    parseInt(value)
  except ValueError:
    raise newException(UsageError, name & " bukan angka: '" & value & "'")

proc parseArgs*(argv: seq[string]): Options =
  result = Options(historyCount: defaultHistoryCount, reps: defaultReps)
  var i = 0
  while i < argv.len:
    case argv[i]
    of "--iterations":
      inc i
      if i >= argv.len:
        raise newException(UsageError, "--iterations butuh nilai")
      result.iterations = parseIntArg("--iterations", argv[i])
    of "--history-count":
      inc i
      if i >= argv.len:
        raise newException(UsageError, "--history-count butuh nilai")
      result.historyCount = parseIntArg("--history-count", argv[i])
    of "--reps":
      inc i
      if i >= argv.len:
        raise newException(UsageError, "--reps butuh nilai")
      result.reps = parseIntArg("--reps", argv[i])
    of "--help", "-h":
      result.help = true
      return
    else:
      raise newException(UsageError, "argumen tidak dikenal: " & argv[i])
    inc i

proc derivationsFor*(historyCount: int): int =
  ## `N + 3` — lihat urutan di kepala `main.nim`. Satu tempat supaya angka yang dihitung dan yang
  ## dilaporkan tidak bisa berbeda.
  historyCount + 3
