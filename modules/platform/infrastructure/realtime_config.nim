## Konfigurasi transport realtime dari parameter (O-030, spec §10.4/§18.2).
##
## Batas pesan langganan (jumlah topik & panjang topik) adalah **pertahanan protokol**, bukan
## ambang bisnis (D-021). Sebelum ini nilainya literal di transport (`32`/`128`); kini berasal
## dari parameter `platform.realtime.max_topics`/`max_topic_len` sehingga bisa diubah per institusi
## tanpa mengubah kode. Transport (`apps/api`) membacanya saat start lalu meneruskan ke lapisan
## application lewat `SubscriptionLimits` (D-030).

import db_connector/db_postgres

import ../application/realtime
import ../domain/scope
import ./param_repo
import kernel/paramkey
import kernel/generated/paramkeys

proc realtimeLimits*(db: DbConn; scope: ScopeRef; asOf: string): SubscriptionLimits =
  ## Batas langganan untuk `scope` pada `asOf`. Gagal-cepat (`ValueError`) bila parameter wajib
  ## tidak punya nilai aktif — perilaku yang sama dengan parameter wajib lain (spec §10.6).
  let lookup = lookupFor(scope)
  SubscriptionLimits(
    maxTopics: db.activeParamInt(
      keyString(P_platform_realtime_max_topics), asOf, lookup),
    maxTopicLen: db.activeParamInt(
      keyString(P_platform_realtime_max_topic_len), asOf, lookup))
