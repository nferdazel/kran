## AuditContext — siapa/untuk apa sebuah use case dipanggil (spec §13).
##
## Konteks ini **wajib** diteruskan ke use case dan ikut tercatat pada audit log
## (spec §9.1(7), §11.7 "alasan" pada parameter). Isinya bukan nilai bisnis.

import std/times
import ./ids, ./clock

type
  AuditContext* = object
    userId*: Id
    branchIds*: seq[Id]  ## cabang yang boleh disentuh (branch scoping, spec §18.2)
    ip*: string
    device*: string
    reason*: string      ## alasan eksplisit; wajib untuk aksi sensitif (unmask, override)
    correlationId*: string
    startedAt*: DateTime ## UTC

proc newAuditContext*(
    userId: Id,
    branchIds: seq[Id] = @[],
    ip = "",
    device = "",
    reason = "",
    correlationId = "",
    startedAt: DateTime,
): AuditContext =
  AuditContext(
    userId: userId,
    branchIds: branchIds,
    ip: ip,
    device: device,
    reason: reason,
    correlationId: correlationId,
    startedAt: startedAt,
  )

proc newAuditContext*(userId: Id, clock: Clock, branchIds: seq[Id] = @[]): AuditContext =
  ## Varian praktis: waktu & correlation ID diambil dari inject.
  newAuditContext(
    userId,
    branchIds = branchIds,
    correlationId = newCorrelationId(),
    startedAt = clock.now(),
  )
