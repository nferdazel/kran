## Permukaan publik modul `hello` (spec §5.5).
##
## Modul lain hanya boleh berbicara lewat berkas ini, bukan import internalnya
## (dijaga `tools/archcheck`).

import ./domain/core
import ./application/use_case

export core, use_case
