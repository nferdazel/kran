// JANGAN EDIT — dihasilkan tools/paramgen dari modules/*/seeds/params.yaml

export type ParamValueType = "integer" | "decimal" | "string" | "bool" | "json" | "enum" | "money" | "rate" | "date";

export interface ParamDefinition {
  readonly key: string;
  readonly module: string;
  readonly valueType: ParamValueType;
  readonly tsType: string;
  readonly scopes: readonly string[];
  readonly sensitivity: "NORMAL" | "CRITICAL";
  readonly requiresApproval: boolean;
  readonly regulatoryRefs: readonly string[];
  readonly descriptionKey: string;
  readonly jsonSchema: unknown;
}

export const paramDefinitions: readonly ParamDefinition[] = [
  {
    "key": "ledger.coa.code_pattern",
    "module": "ledger",
    "valueType": "string",
    "tsType": "string",
    "scopes": [
      "GLOBAL",
      "INSTITUTION"
    ],
    "sensitivity": "NORMAL",
    "requiresApproval": true,
    "regulatoryRefs": [],
    "descriptionKey": "param.ledger.coa.code_pattern",
    "jsonSchema": {
      "minLength": 5,
      "maxLength": 120
    }
  },
  {
    "key": "party.cif.format",
    "module": "party",
    "valueType": "string",
    "tsType": "string",
    "scopes": [
      "GLOBAL",
      "INSTITUTION"
    ],
    "sensitivity": "NORMAL",
    "requiresApproval": true,
    "regulatoryRefs": [],
    "descriptionKey": "param.party.cif.format",
    "jsonSchema": {
      "minLength": 5,
      "maxLength": 24
    }
  },
  {
    "key": "party.identity.doc_lengths",
    "module": "party",
    "valueType": "json",
    "tsType": "unknown",
    "scopes": [
      "GLOBAL",
      "INSTITUTION"
    ],
    "sensitivity": "NORMAL",
    "requiresApproval": true,
    "regulatoryRefs": [],
    "descriptionKey": "param.party.identity.doc_lengths",
    "jsonSchema": {
      "type": "object"
    }
  },
  {
    "key": "party.identity.doc_types",
    "module": "party",
    "valueType": "json",
    "tsType": "unknown",
    "scopes": [
      "GLOBAL",
      "INSTITUTION"
    ],
    "sensitivity": "NORMAL",
    "requiresApproval": true,
    "regulatoryRefs": [],
    "descriptionKey": "param.party.identity.doc_types",
    "jsonSchema": {
      "type": "array"
    }
  },
  {
    "key": "party.identity.number_max_length",
    "module": "party",
    "valueType": "integer",
    "tsType": "string",
    "scopes": [
      "GLOBAL",
      "INSTITUTION"
    ],
    "sensitivity": "NORMAL",
    "requiresApproval": true,
    "regulatoryRefs": [],
    "descriptionKey": "param.party.identity.number_max_length",
    "jsonSchema": {
      "minimum": 4,
      "maximum": 64
    }
  },
  {
    "key": "party.kyc.default_risk_level",
    "module": "party",
    "valueType": "string",
    "tsType": "string",
    "scopes": [
      "GLOBAL",
      "INSTITUTION"
    ],
    "sensitivity": "NORMAL",
    "requiresApproval": true,
    "regulatoryRefs": [],
    "descriptionKey": "param.party.kyc.default_risk_level",
    "jsonSchema": {
      "minLength": 1,
      "maxLength": 32
    }
  },
  {
    "key": "party.kyc.review_months",
    "module": "party",
    "valueType": "json",
    "tsType": "unknown",
    "scopes": [
      "GLOBAL",
      "INSTITUTION"
    ],
    "sensitivity": "NORMAL",
    "requiresApproval": true,
    "regulatoryRefs": [],
    "descriptionKey": "param.party.kyc.review_months",
    "jsonSchema": {
      "type": "object"
    }
  },
  {
    "key": "party.kyc.risk_levels",
    "module": "party",
    "valueType": "json",
    "tsType": "unknown",
    "scopes": [
      "GLOBAL",
      "INSTITUTION"
    ],
    "sensitivity": "NORMAL",
    "requiresApproval": true,
    "regulatoryRefs": [],
    "descriptionKey": "param.party.kyc.risk_levels",
    "jsonSchema": {
      "type": "array"
    }
  },
  {
    "key": "platform.calendar.fiscal_year_start_month",
    "module": "platform",
    "valueType": "integer",
    "tsType": "string",
    "scopes": [
      "GLOBAL"
    ],
    "sensitivity": "NORMAL",
    "requiresApproval": true,
    "regulatoryRefs": [],
    "descriptionKey": "param.platform.calendar.fiscal_year_start_month",
    "jsonSchema": {
      "minimum": 1,
      "maximum": 12
    }
  },
  {
    "key": "platform.calendar.weekend_days",
    "module": "platform",
    "valueType": "json",
    "tsType": "unknown",
    "scopes": [
      "GLOBAL",
      "BRANCH"
    ],
    "sensitivity": "NORMAL",
    "requiresApproval": true,
    "regulatoryRefs": [],
    "descriptionKey": "param.platform.calendar.weekend_days",
    "jsonSchema": {
      "type": "array"
    }
  },
  {
    "key": "platform.realtime.max_topic_len",
    "module": "platform",
    "valueType": "integer",
    "tsType": "string",
    "scopes": [
      "GLOBAL",
      "INSTITUTION"
    ],
    "sensitivity": "NORMAL",
    "requiresApproval": true,
    "regulatoryRefs": [],
    "descriptionKey": "param.platform.realtime.max_topic_len",
    "jsonSchema": {
      "minimum": 1,
      "maximum": 4096
    }
  },
  {
    "key": "platform.realtime.max_topics",
    "module": "platform",
    "valueType": "integer",
    "tsType": "string",
    "scopes": [
      "GLOBAL",
      "INSTITUTION"
    ],
    "sensitivity": "NORMAL",
    "requiresApproval": true,
    "regulatoryRefs": [],
    "descriptionKey": "param.platform.realtime.max_topics",
    "jsonSchema": {
      "minimum": 1,
      "maximum": 1000
    }
  },
  {
    "key": "platform.security.lockout_minutes",
    "module": "platform",
    "valueType": "integer",
    "tsType": "string",
    "scopes": [
      "GLOBAL",
      "INSTITUTION"
    ],
    "sensitivity": "NORMAL",
    "requiresApproval": true,
    "regulatoryRefs": [],
    "descriptionKey": "param.platform.security.lockout_minutes",
    "jsonSchema": {
      "minimum": 1,
      "maximum": 1440
    }
  },
  {
    "key": "platform.security.max_failed_logins",
    "module": "platform",
    "valueType": "integer",
    "tsType": "string",
    "scopes": [
      "GLOBAL",
      "INSTITUTION"
    ],
    "sensitivity": "NORMAL",
    "requiresApproval": true,
    "regulatoryRefs": [],
    "descriptionKey": "param.platform.security.max_failed_logins",
    "jsonSchema": {
      "minimum": 1,
      "maximum": 100
    }
  },
  {
    "key": "platform.security.mfa.digits",
    "module": "platform",
    "valueType": "integer",
    "tsType": "string",
    "scopes": [
      "GLOBAL"
    ],
    "sensitivity": "NORMAL",
    "requiresApproval": true,
    "regulatoryRefs": [],
    "descriptionKey": "param.platform.security.mfa.digits",
    "jsonSchema": {
      "minimum": 6,
      "maximum": 8
    }
  },
  {
    "key": "platform.security.mfa.drift_steps",
    "module": "platform",
    "valueType": "integer",
    "tsType": "string",
    "scopes": [
      "GLOBAL"
    ],
    "sensitivity": "NORMAL",
    "requiresApproval": true,
    "regulatoryRefs": [],
    "descriptionKey": "param.platform.security.mfa.drift_steps",
    "jsonSchema": {
      "minimum": 0,
      "maximum": 5
    }
  },
  {
    "key": "platform.security.mfa.enabled",
    "module": "platform",
    "valueType": "bool",
    "tsType": "boolean",
    "scopes": [
      "GLOBAL",
      "INSTITUTION"
    ],
    "sensitivity": "NORMAL",
    "requiresApproval": true,
    "regulatoryRefs": [],
    "descriptionKey": "param.platform.security.mfa.enabled",
    "jsonSchema": null
  },
  {
    "key": "platform.security.mfa.issuer",
    "module": "platform",
    "valueType": "string",
    "tsType": "string",
    "scopes": [
      "GLOBAL",
      "INSTITUTION"
    ],
    "sensitivity": "NORMAL",
    "requiresApproval": true,
    "regulatoryRefs": [],
    "descriptionKey": "param.platform.security.mfa.issuer",
    "jsonSchema": {
      "minLength": 1,
      "maxLength": 64
    }
  },
  {
    "key": "platform.security.mfa.period_seconds",
    "module": "platform",
    "valueType": "integer",
    "tsType": "string",
    "scopes": [
      "GLOBAL"
    ],
    "sensitivity": "NORMAL",
    "requiresApproval": true,
    "regulatoryRefs": [],
    "descriptionKey": "param.platform.security.mfa.period_seconds",
    "jsonSchema": {
      "minimum": 15,
      "maximum": 300
    }
  },
  {
    "key": "platform.security.password_history_count",
    "module": "platform",
    "valueType": "integer",
    "tsType": "string",
    "scopes": [
      "GLOBAL",
      "INSTITUTION"
    ],
    "sensitivity": "NORMAL",
    "requiresApproval": true,
    "regulatoryRefs": [],
    "descriptionKey": "param.platform.security.password_history_count",
    "jsonSchema": {
      "minimum": 0,
      "maximum": 24
    }
  },
  {
    "key": "platform.security.password_min_classes",
    "module": "platform",
    "valueType": "integer",
    "tsType": "string",
    "scopes": [
      "GLOBAL",
      "INSTITUTION"
    ],
    "sensitivity": "CRITICAL",
    "requiresApproval": true,
    "regulatoryRefs": [],
    "descriptionKey": "param.platform.security.password_min_classes",
    "jsonSchema": {
      "minimum": 1,
      "maximum": 4
    }
  },
  {
    "key": "platform.security.password_min_length",
    "module": "platform",
    "valueType": "integer",
    "tsType": "string",
    "scopes": [
      "GLOBAL",
      "INSTITUTION"
    ],
    "sensitivity": "CRITICAL",
    "requiresApproval": true,
    "regulatoryRefs": [],
    "descriptionKey": "param.platform.security.password_min_length",
    "jsonSchema": {
      "minimum": 8,
      "maximum": 64
    }
  },
  {
    "key": "platform.security.password_pbkdf2_iterations",
    "module": "platform",
    "valueType": "integer",
    "tsType": "string",
    "scopes": [
      "GLOBAL",
      "INSTITUTION"
    ],
    "sensitivity": "NORMAL",
    "requiresApproval": true,
    "regulatoryRefs": [],
    "descriptionKey": "param.platform.security.password_pbkdf2_iterations",
    "jsonSchema": {
      "minimum": 1000,
      "maximum": 5000000
    }
  },
  {
    "key": "platform.security.session_absolute_minutes",
    "module": "platform",
    "valueType": "integer",
    "tsType": "string",
    "scopes": [
      "GLOBAL",
      "INSTITUTION"
    ],
    "sensitivity": "NORMAL",
    "requiresApproval": true,
    "regulatoryRefs": [],
    "descriptionKey": "param.platform.security.session_absolute_minutes",
    "jsonSchema": {
      "minimum": 5,
      "maximum": 1440
    }
  },
  {
    "key": "platform.security.session_idle_minutes",
    "module": "platform",
    "valueType": "integer",
    "tsType": "string",
    "scopes": [
      "GLOBAL",
      "INSTITUTION"
    ],
    "sensitivity": "NORMAL",
    "requiresApproval": true,
    "regulatoryRefs": [],
    "descriptionKey": "param.platform.security.session_idle_minutes",
    "jsonSchema": {
      "minimum": 1,
      "maximum": 1440
    }
  }
] as const;
