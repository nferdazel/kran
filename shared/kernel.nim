## `kernel` — umbrella shared kernel (spec §5.2). Kecil & stabil; tanpa "utils" serbaguna.
##
## `import kernel` membawa tipe inti: `Result`/`AppError`, `Money`, `Rate`, `BusinessDate`,
## `Clock`, `Id`, `AuditContext`, plus `paramkey` (kontrak parameter, spec §10.2–§10.4).

import ./kernel/result
import ./kernel/rate
import ./kernel/money
import ./kernel/businessdate
import ./kernel/clock
import ./kernel/ids
import ./kernel/auditcontext
import ./kernel/paramkey

export result, rate, money, businessdate, clock, ids, auditcontext, paramkey
