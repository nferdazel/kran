## JANGAN EDIT — dihasilkan tools/paramgen dari modules/*/seeds/params.yaml
##
## Ubah definisi di `modules/<m>/seeds/params.yaml`, lalu jalankan `./task paramgen-gen`.

import ../paramkey

const paramKeys*: seq[string] = @[
  "platform.calendar.fiscal_year_start_month",
  "platform.security.password_min_length",
  "platform.security.session_idle_minutes",
]

const P_platform_calendar_fiscal_year_start_month* = ParamKey[int64]("platform.calendar.fiscal_year_start_month")

const P_platform_security_password_min_length* = ParamKey[int64]("platform.security.password_min_length")

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
