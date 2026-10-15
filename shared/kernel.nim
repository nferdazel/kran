## `shared/kernel` — shared kernel kecil & stabil (spec §5.2).
##
## Isi yang sengaja ada: tipe nilai uang/rate/tanggal, `Result`, `Clock`, `Id`,
## `AuditContext`, dan kontrak key parameter. **Tidak boleh** ada "utils" serbaguna di sini.
##
## Modul KRAN sebaiknya `import kernel` (berkas ini) untuk permukaan lengkap, atau impor
## submodul spesifik (`import kernel/money`) bila ingin lebih sempit.

import kernel/result
import kernel/paramkey
import kernel/rate
import kernel/money
import kernel/businessdate
import kernel/clock
import kernel/ids
import kernel/auditcontext

export result
export paramkey
export rate
export money
export businessdate
export clock
export ids
export auditcontext
