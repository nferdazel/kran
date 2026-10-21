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
    "key": "ledger.posting.batch_size",
    "module": "ledger",
    "valueType": "integer",
    "tsType": "string",
    "scopes": [
      "GLOBAL",
      "INSTITUTION"
    ],
    "sensitivity": "NORMAL",
    "requiresApproval": true,
    "regulatoryRefs": [],
    "descriptionKey": "param.ledger.posting.batch_size",
    "jsonSchema": {
      "minimum": 1,
      "maximum": 500
    }
  },
  {
    "key": "ledger.posting.lease_seconds",
    "module": "ledger",
    "valueType": "integer",
    "tsType": "string",
    "scopes": [
      "GLOBAL",
      "INSTITUTION"
    ],
    "sensitivity": "NORMAL",
    "requiresApproval": true,
    "regulatoryRefs": [],
    "descriptionKey": "param.ledger.posting.lease_seconds",
    "jsonSchema": {
      "minimum": 30,
      "maximum": 3600
    }
  },
  {
    "key": "ledger.posting.max_attempts",
    "module": "ledger",
    "valueType": "integer",
    "tsType": "string",
    "scopes": [
      "GLOBAL",
      "INSTITUTION"
    ],
    "sensitivity": "NORMAL",
    "requiresApproval": true,
    "regulatoryRefs": [],
    "descriptionKey": "param.ledger.posting.max_attempts",
    "jsonSchema": {
      "minimum": 1,
      "maximum": 100
    }
  },
  {
    "key": "ledger.posting.poll_interval_ms",
    "module": "ledger",
    "valueType": "integer",
    "tsType": "string",
    "scopes": [
      "GLOBAL",
      "INSTITUTION"
    ],
    "sensitivity": "NORMAL",
    "requiresApproval": true,
    "regulatoryRefs": [],
    "descriptionKey": "param.ledger.posting.poll_interval_ms",
    "jsonSchema": {
      "minimum": 50,
      "maximum": 60000
    }
  },
  {
    "key": "ledger.posting.retry_backoff_seconds",
    "module": "ledger",
    "valueType": "integer",
    "tsType": "string",
    "scopes": [
      "GLOBAL",
      "INSTITUTION"
    ],
    "sensitivity": "NORMAL",
    "requiresApproval": true,
    "regulatoryRefs": [],
    "descriptionKey": "param.ledger.posting.retry_backoff_seconds",
    "jsonSchema": {
      "minimum": 1,
      "maximum": 86400
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
    "key": "platform.idempotency.ttl_hours",
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
    "descriptionKey": "param.platform.idempotency.ttl_hours",
    "jsonSchema": {
      "minimum": 1,
      "maximum": 8760
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
  },
  {
    "key": "product.savings.admin_fee",
    "module": "product",
    "valueType": "money",
    "tsType": "string",
    "scopes": [
      "GLOBAL",
      "INSTITUTION"
    ],
    "sensitivity": "NORMAL",
    "requiresApproval": true,
    "regulatoryRefs": [],
    "descriptionKey": "param.product.savings.admin_fee",
    "jsonSchema": {
      "minimum": 0
    }
  },
  {
    "key": "product.savings.day_count_basis",
    "module": "product",
    "valueType": "enum",
    "tsType": "\"ACT_365\" | \"ACT_360\" | \"THIRTY_360\"",
    "scopes": [
      "GLOBAL",
      "INSTITUTION"
    ],
    "sensitivity": "NORMAL",
    "requiresApproval": true,
    "regulatoryRefs": [],
    "descriptionKey": "param.product.savings.day_count_basis",
    "jsonSchema": {
      "enum": [
        "ACT_365",
        "ACT_360",
        "THIRTY_360"
      ]
    }
  },
  {
    "key": "product.savings.grace_period_days",
    "module": "product",
    "valueType": "integer",
    "tsType": "string",
    "scopes": [
      "GLOBAL",
      "INSTITUTION"
    ],
    "sensitivity": "NORMAL",
    "requiresApproval": true,
    "regulatoryRefs": [],
    "descriptionKey": "param.product.savings.grace_period_days",
    "jsonSchema": {
      "minimum": 0,
      "maximum": 365
    }
  },
  {
    "key": "product.savings.interest_posting",
    "module": "product",
    "valueType": "enum",
    "tsType": "\"NONE\" | \"MONTH_END\"",
    "scopes": [
      "GLOBAL",
      "INSTITUTION"
    ],
    "sensitivity": "NORMAL",
    "requiresApproval": true,
    "regulatoryRefs": [],
    "descriptionKey": "param.product.savings.interest_posting",
    "jsonSchema": {
      "enum": [
        "NONE",
        "MONTH_END"
      ]
    }
  },
  {
    "key": "product.savings.interest_rate",
    "module": "product",
    "valueType": "rate",
    "tsType": "string",
    "scopes": [
      "GLOBAL",
      "INSTITUTION"
    ],
    "sensitivity": "NORMAL",
    "requiresApproval": true,
    "regulatoryRefs": [],
    "descriptionKey": "param.product.savings.interest_rate",
    "jsonSchema": {
      "maxLength": 32
    }
  },
  {
    "key": "product.savings.min_balance",
    "module": "product",
    "valueType": "money",
    "tsType": "string",
    "scopes": [
      "GLOBAL",
      "INSTITUTION"
    ],
    "sensitivity": "NORMAL",
    "requiresApproval": true,
    "regulatoryRefs": [],
    "descriptionKey": "param.product.savings.min_balance",
    "jsonSchema": {
      "minimum": 0
    }
  },
  {
    "key": "product.savings.rounding_mode",
    "module": "product",
    "valueType": "enum",
    "tsType": "\"HALF_UP\" | \"HALF_EVEN\"",
    "scopes": [
      "GLOBAL",
      "INSTITUTION"
    ],
    "sensitivity": "NORMAL",
    "requiresApproval": true,
    "regulatoryRefs": [],
    "descriptionKey": "param.product.savings.rounding_mode",
    "jsonSchema": {
      "enum": [
        "HALF_UP",
        "HALF_EVEN"
      ]
    }
  },
  {
    "key": "product.savings.rounding_scale",
    "module": "product",
    "valueType": "integer",
    "tsType": "string",
    "scopes": [
      "GLOBAL",
      "INSTITUTION"
    ],
    "sensitivity": "NORMAL",
    "requiresApproval": true,
    "regulatoryRefs": [],
    "descriptionKey": "param.product.savings.rounding_scale",
    "jsonSchema": {
      "minimum": 0,
      "maximum": 4
    }
  }
] as const;
