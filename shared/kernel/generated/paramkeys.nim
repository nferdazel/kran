## JANGAN EDIT — dihasilkan tools/paramgen dari modules/*/seeds/params.yaml
##
## Ubah definisi di `modules/<m>/seeds/params.yaml`, lalu jalankan `./task paramgen-gen`.

import ../paramkey
import std/json

const paramKeys*: seq[string] = @[
  "platform.calendar.fiscal_year_start_month",
  "platform.calendar.weekend_days",
  "platform.realtime.max_topic_len",
  "platform.realtime.max_topics",
  "platform.security.lockout_minutes",
  "platform.security.max_failed_logins",
  "platform.security.password_min_length",
  "platform.security.password_pbkdf2_iterations",
  "platform.security.session_absolute_minutes",
  "platform.security.session_idle_minutes",
]

const P_platform_calendar_fiscal_year_start_month* = ParamKey[int64]("platform.calendar.fiscal_year_start_month")

const P_platform_calendar_weekend_days* = ParamKey[JsonNode]("platform.calendar.weekend_days")

const P_platform_realtime_max_topic_len* = ParamKey[int64]("platform.realtime.max_topic_len")

const P_platform_realtime_max_topics* = ParamKey[int64]("platform.realtime.max_topics")

const P_platform_security_lockout_minutes* = ParamKey[int64]("platform.security.lockout_minutes")

const P_platform_security_max_failed_logins* = ParamKey[int64]("platform.security.max_failed_logins")

const P_platform_security_password_min_length* = ParamKey[int64]("platform.security.password_min_length")

const P_platform_security_password_pbkdf2_iterations* = ParamKey[int64]("platform.security.password_pbkdf2_iterations")

const P_platform_security_session_absolute_minutes* = ParamKey[int64]("platform.security.session_absolute_minutes")

const P_platform_security_session_idle_minutes* = ParamKey[int64]("platform.security.session_idle_minutes")

const paramDefinitions*: seq[ParamDefinition] = @[
  ParamDefinition(
    key: "platform.calendar.fiscal_year_start_month",
    module: "platform",
    valueType: pvtInteger,
    scopes: {pstGlobal},
    sensitivity: psNormal,
    requiresApproval: true,
    regulatoryRefs: @[],
    descriptionKey: "param.platform.calendar.fiscal_year_start_month",
    sinceVersion: "0.1.0",
  ),
  ParamDefinition(
    key: "platform.calendar.weekend_days",
    module: "platform",
    valueType: pvtJson,
    scopes: {pstGlobal, pstBranch},
    sensitivity: psNormal,
    requiresApproval: true,
    regulatoryRefs: @[],
    descriptionKey: "param.platform.calendar.weekend_days",
    sinceVersion: "0.1.0",
  ),
  ParamDefinition(
    key: "platform.realtime.max_topic_len",
    module: "platform",
    valueType: pvtInteger,
    scopes: {pstGlobal, pstInstitution},
    sensitivity: psNormal,
    requiresApproval: true,
    regulatoryRefs: @[],
    descriptionKey: "param.platform.realtime.max_topic_len",
    sinceVersion: "0.1.0",
  ),
  ParamDefinition(
    key: "platform.realtime.max_topics",
    module: "platform",
    valueType: pvtInteger,
    scopes: {pstGlobal, pstInstitution},
    sensitivity: psNormal,
    requiresApproval: true,
    regulatoryRefs: @[],
    descriptionKey: "param.platform.realtime.max_topics",
    sinceVersion: "0.1.0",
  ),
  ParamDefinition(
    key: "platform.security.lockout_minutes",
    module: "platform",
    valueType: pvtInteger,
    scopes: {pstGlobal, pstInstitution},
    sensitivity: psNormal,
    requiresApproval: true,
    regulatoryRefs: @[],
    descriptionKey: "param.platform.security.lockout_minutes",
    sinceVersion: "0.1.0",
  ),
  ParamDefinition(
    key: "platform.security.max_failed_logins",
    module: "platform",
    valueType: pvtInteger,
    scopes: {pstGlobal, pstInstitution},
    sensitivity: psNormal,
    requiresApproval: true,
    regulatoryRefs: @[],
    descriptionKey: "param.platform.security.max_failed_logins",
    sinceVersion: "0.1.0",
  ),
  ParamDefinition(
    key: "platform.security.password_min_length",
    module: "platform",
    valueType: pvtInteger,
    scopes: {pstGlobal, pstInstitution},
    sensitivity: psCritical,
    requiresApproval: true,
    regulatoryRefs: @[],
    descriptionKey: "param.platform.security.password_min_length",
    sinceVersion: "0.1.0",
  ),
  ParamDefinition(
    key: "platform.security.password_pbkdf2_iterations",
    module: "platform",
    valueType: pvtInteger,
    scopes: {pstGlobal, pstInstitution},
    sensitivity: psNormal,
    requiresApproval: true,
    regulatoryRefs: @[],
    descriptionKey: "param.platform.security.password_pbkdf2_iterations",
    sinceVersion: "0.1.0",
  ),
  ParamDefinition(
    key: "platform.security.session_absolute_minutes",
    module: "platform",
    valueType: pvtInteger,
    scopes: {pstGlobal, pstInstitution},
    sensitivity: psNormal,
    requiresApproval: true,
    regulatoryRefs: @[],
    descriptionKey: "param.platform.security.session_absolute_minutes",
    sinceVersion: "0.1.0",
  ),
  ParamDefinition(
    key: "platform.security.session_idle_minutes",
    module: "platform",
    valueType: pvtInteger,
    scopes: {pstGlobal, pstInstitution},
    sensitivity: psNormal,
    requiresApproval: true,
    regulatoryRefs: @[],
    descriptionKey: "param.platform.security.session_idle_minutes",
    sinceVersion: "0.1.0",
  ),
]
