## Permukaan publik modul `product` (spec §5.5).
##
## Modul lain hanya boleh berbicara lewat berkas ini, bukan import internalnya
## (dijaga `tools/archcheck`).

import ./domain/product

export product
