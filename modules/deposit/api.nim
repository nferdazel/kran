## Permukaan publik modul `deposit` (spec §5.5).
##
## Modul lain hanya boleh berbicara lewat berkas ini, bukan import internalnya (dijaga
## `tools/archcheck`). Repositori DB sengaja **tidak** diekspor: yang boleh menyentuhnya hanya
## composition root (`apps/api`) dan test modul.

import ./domain/account
import ./domain/transaction
import ./domain/transfer

export account
export transaction
export transfer
