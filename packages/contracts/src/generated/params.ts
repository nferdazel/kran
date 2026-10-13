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

export const paramDefinitions: readonly ParamDefinition[] = [] as const;
