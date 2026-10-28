## Permukaan publik modul `deposit` (spec §5.5).
##
## Modul lain hanya boleh berbicara lewat berkas ini, bukan import internalnya (dijaga
## `tools/archcheck`). Repositori DB sengaja **tidak** diekspor: yang boleh menyentuhnya hanya
## composition root (`apps/api`) dan test modul.

import ./domain/account
import ./domain/[daycount, interest]
import ./domain/transaction
import ./domain/transfer

export account
export daycount, interest
export transaction
export transfer
