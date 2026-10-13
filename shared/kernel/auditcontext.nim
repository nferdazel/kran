## `AuditContext` — konteks audit (spec §13: siapa, cabang, IP, device, alasan) yang otomatis
## diteruskan ke use case. `userId` = id pelaku; `branchIds` = cakupan cabang (branch scoping).

import std/times

import ./ids
import ./clock

type
  ## Konteks audit satu aksi. `startedAt` eksplisit agar domain tetap bebas waktu implisit.
  AuditContext* = object
    userId*: Id
    branchIds*: seq[Id]
    ip*, device*, reason*, correlationId*: string
    startedAt*: DateTime

proc newAuditContext*(userId: Id, branchIds: seq[Id] = @[], ip = "", device = "", reason = "",
                      correlationId = "", startedAt: DateTime): AuditContext =
  ## Bangun konteks audit; `startedAt` wajib eksplisit.
  AuditContext(userId: userId, branchIds: branchIds, ip: ip, device: device, reason: reason,
               correlationId: correlationId, startedAt: startedAt)

proc newAuditContext*(userId: Id; clock: Clock; branchIds: seq[Id] = @[], ip = "",
                      device = "", reason = "", correlationId = ""): AuditContext =
  ## Overload: `startedAt` diambil dari `clock` (UTC).
  newAuditContext(userId, branchIds, ip, device, reason, correlationId, clock.now())
