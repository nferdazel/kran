## bench-password — ukur latensi/CPU ganti kata sandi (T-060, menutup O-068).
##
## **Kenapa**: `POST /api/v1/auth/password` (`apps/api/src/handlers_auth.nim`) memanggil
## `auth_service.changePassword` (`modules/platform/infrastructure/auth_service.nim:283-338`) yang
## menjalankan PBKDF2 pada urutan berikut:
##
##   1. verifikasi kata sandi **lama** terhadap hash yang berlaku,                     `:298`
##   2. verifikasi kata sandi **baru** terhadap hash yang berlaku,                     `:321`
##   3. verifikasi kata sandi baru terhadap N hash riwayat (bila langkah 2 gagal),     `:324-328`
##   4. hash kata sandi baru.                                                          `:331`
##
## Jadi biayanya **N + 3** derivasi PBKDF2 (bukan "dua kali" seperti klaim lama), dengan N =
## `platform.security.password_history_count` (basis 5) → **8 derivasi** saat N = 5. Langkah 2
## selalu ada karena akun hasil `bootstrap-admin` belum punya baris riwayat — lihat D-058 butir 6.
##
## Alat ini **memakai fungsi kripto nyata** (`password_hasher.hashPassword`/`verifyPassword`, yang
## sama persis dipanggil `changePassword`) dengan jumlah iterasi nyata dari parameter, dan
## mereproduksi urutan di atas apa adanya. Yang **tidak** diukur: perjalanan DB (tunnel/dev) dan
## penulisan audit — keduanya konstanta per permintaan yang tidak berubah bersama N, dan sudah
## dibatasi tenggang e2e (`apps/web/playwright.config.ts`). Angka di sini karena itu batas bawah
## yang jujur untuk komponen CPU yang **memang** berlipat bersama N (inti O-068).
##
## Bilangan derivasi dilaporkan `derivationsFor()` supaya tidak bisa menyimpang dari yang dihitung.
##
## **Build release**: `./task bench-password` mengompilasi dengan `-d:release`, sama seperti biner
## produksi (`apps/api/Dockerfile:41`). Build debug ~20x lebih lambat, jadi angka debug tidak
## menggambarkan biaya nyata. Dev/CI e2e memakai build debug (`./task build`); itu sebabnya tenggang
## e2e dibuat lebar — bukan karena biaya produksinya.
##
## Keluar: 0 sukses, 2 kesalahan pemakaian.
##
## Dijalankan `./task bench-password --iterations <n>` (lihat `./task help`).

import std/[algorithm, os, strutils, times]

import platform/infrastructure/password_hasher

import ./benchlib

const
  oldPassword = "Kata-Sandi-Lama-Benchmark"
  newPassword = "Kata-Sandi-Baru-Benchmark"

proc usage() =
  echo "pemakaian: bench-password --iterations <n> [--history-count <n>] [--reps <n>]"
  echo "  --iterations <n>   jumlah iterasi PBKDF2 (nilai produksi/dev = parameter"
  echo "                     `platform.security.password_pbkdf2_iterations`; lihat pack seed)."
  echo "  --history-count <n> N hash riwayat yang diverifikasi (bawaan 5)."
  echo "  --reps <n>          ulangan per N; dilaporkan median (bawaan 3)."
  echo "  Dibangun release oleh ./task bench-password (angkanya menggambarkan biner produksi)."

proc median(xs: seq[float]): float =
  var s = xs
  s.sort()
  s[s.len div 2]

proc measure(iterations, historyCount, reps: int) =
  echo "bench-password: kdf-only iterations=" & $iterations & " reps=" & $reps
  var counts = @[0]
  if historyCount > 0:
    counts.add historyCount
  for n in counts:
    let currentHash = $hashPassword(oldPassword, iterations)
    var history: seq[string]
    for i in 0 ..< n:
      history.add $hashPassword("riwayat-" & $i & "-benchmark", iterations)
    var wall, cpu: seq[float]
    for _ in 0 ..< reps:
      let w0 = epochTime()
      let c0 = cpuTime()
      # Urutan yang sama dengan `changePassword` (jangan disederhanakan: jumlah derivasi = biaya).
      doAssert verifyPassword(oldPassword, currentHash)
      doAssert not verifyPassword(newPassword, currentHash)
      for h in history:
        discard verifyPassword(newPassword, h)
      discard hashPassword(newPassword, iterations)
      wall.add(epochTime() - w0)
      cpu.add(cpuTime() - c0)
    echo "  N=" & $n & " derivations=" & $derivationsFor(n) &
      " wall_median_ms=" & formatFloat(median(wall) * 1000.0, ffDecimal, 1) &
      " cpu_median_ms=" & formatFloat(median(cpu) * 1000.0, ffDecimal, 1)

proc main() =
  var opts: Options
  try:
    opts = parseArgs(commandLineParams())
  except UsageError as e:
    quit(e.msg, 2)
  if opts.help:
    usage()
    quit(0)
  if opts.iterations <= 0:
    usage()
    quit("--iterations <n> wajib (nilai: parameter platform.security.password_pbkdf2_iterations)", 2)
  if opts.reps < 1:
    quit("--reps minimal 1", 2)
  if opts.historyCount < 0:
    quit("--history-count minimal 0", 2)
  measure(opts.iterations, opts.historyCount, opts.reps)

main()
