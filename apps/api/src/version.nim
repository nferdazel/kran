## Versi aplikasi (spec §21.4: `/healthz` dan log startup).
##
## Sumber: `VERSION` di root repo. `tools/gen-version.sh` menstempelnya ke `version_gen.nim`
## saat `./task build`, dan `./task check-fast` gagal bila berkas generated tidak lagi sama.
## `KRAN_VERSION` (env/systemd) tetap menang bila diisi — deploy mengisinya dengan tag rilis,
## sehingga proses yang berjalan tidak bergantung pada kapan binary dibangun.

import std/os

import ./version_gen

export version_gen

proc appVersion*(): string =
  let fromEnv = getEnv("KRAN_VERSION")
  if fromEnv.len > 0: fromEnv else: AppVersion
