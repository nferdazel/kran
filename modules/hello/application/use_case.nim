## Lapisan application modul `hello` (spec §7): use case + port.
##
## Boleh tahu domain modul ini dan port yang didefinisikan di sini; TIDAK boleh menyentuh
## driver DB/HTTP (dijaga `tools/archcheck`).

import ../domain/core

proc greetUser*(who: string): string =
  ## Contoh use case: memanggil domain. Ganti dengan use case sesungguhnya.
  greet(who)
