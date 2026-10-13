## Domain murni modul `hello` (spec §5.5).
##
## Ganti berkas contoh ini dengan entity/value object/domain service sesungguhnya.
## Lapisan ini murni: tanpa I/O, DB, atau import internal modul lain — dijaga
## `tools/archcheck`.

proc greet*(who: string): string =
  ## Contoh fungsi murni; tanpa nilai bisnis apa pun (spec §10.4).
  "Halo, " & who & "!"
