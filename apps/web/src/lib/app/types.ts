/**
 * Tipe hasil kontrak OpenAPI yang dipakai UI (spec §13): diturunkan langsung dari skema yang
 * dihasilkan `openapi-typescript`, bukan salinan tangan — supaya perubahan kontrak terlihat
 * sebagai error tipe di sini.
 */
import type { components } from "@kran/api-client/schema";

export type SessionInfo = components["schemas"]["SessionInfo"];
export type ParamValue = components["schemas"]["ParamValue"];
export type AuditItem = components["schemas"]["AuditItem"];
export type Product = components["schemas"]["Product"];
export type ProductSummary = components["schemas"]["ProductSummary"];
export type ProductVersion = components["schemas"]["ProductVersion"];
