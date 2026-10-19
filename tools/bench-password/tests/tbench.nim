import std/unittest

import ../benchlib

suite "bench-password: angka turunan":
  test "N+3 (bukan N+2)":
    check derivationsFor(0) == 3
    check derivationsFor(1) == 4
    check derivationsFor(5) == 8

suite "bench-password: parsing argumen":
  test "bawaan":
    let o = parseArgs(@["--iterations", "600000"])
    check o.iterations == 600000
    check o.historyCount == 5
    check o.reps == 3
    check not o.help

  test "semua opsi":
    let o = parseArgs(@["--iterations", "600000", "--history-count", "2", "--reps", "1"])
    check o.iterations == 600000
    check o.historyCount == 2
    check o.reps == 1

  test "--help dikenali":
    check parseArgs(@["--help"]).help
    check parseArgs(@["-h"]).help

  test "angka bukan angka -> UsageError (exit 2, bukan jejak tumpukan)":
    expect UsageError:
      discard parseArgs(@["--iterations", "abc"])
    expect UsageError:
      discard parseArgs(@["--history-count", "x"])
    expect UsageError:
      discard parseArgs(@["--reps", ""])

  test "nilai hilang":
    expect UsageError:
      discard parseArgs(@["--iterations"])
    expect UsageError:
      discard parseArgs(@["--history-count"])
    expect UsageError:
      discard parseArgs(@["--reps"])

  test "argumen tidak dikenal":
    expect UsageError:
      discard parseArgs(@["--nope"])
