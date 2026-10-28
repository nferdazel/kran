## Permukaan publik modul `daycloser` (spec §5.5, §11.4).
##
## Modul lain memakai berkas ini hanya untuk **mendeklarasikan task**: tipe kontrak + helper
## outcome. Registry dan orkestrator tidak diekspor — keduanya dijalankan composition root
## (`apps/api`), yang juga pemilik koneksi DB dan urutan registrasi.
##
## Repositori DB sengaja tidak diekspor: test modul dan composition root boleh menyentuhnya,
## modul bisnis lain tidak (dijaga `tools/archcheck`).

import ./domain/[schedule, types]

export schedule, types
