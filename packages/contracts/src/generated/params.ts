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
