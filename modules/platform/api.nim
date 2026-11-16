## Permukaan publik modul `platform` (spec §5.5).
##
## Sampai sekarang modul ini belum punya `api.nim`: composition root di `apps/api` menembus
## `infrastructure/` langsung, dan itu tercatat sebagai utang di baseline archcheck. Berkas ini
## tidak memperbaiki utang itu, hanya memastikan **permukaan baru** (retensi outbox/inbox, T-282)
## tidak menambah satu baris pun ke baseline.
##
## Yang diekspor sengaja sempit: ambang retensi dan dua perintah hapus. Repositori lain tetap
## internal modul sampai ada task yang memindahkannya.

import ./infrastructure/retention_repo

export retention_repo.retentionDays, retention_repo.purgeOutbox, retention_repo.purgeInbox
