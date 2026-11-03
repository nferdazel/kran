/**
 * Tipe hasil kontrak OpenAPI yang dipakai UI (spec §13): diturunkan langsung dari skema yang
 * dihasilkan `openapi-typescript`, bukan salinan tangan — supaya perubahan kontrak terlihat
 * sebagai error tipe di sini.
 */
import type { components } from "@kran/api-client/schema";

export type SessionInfo = components["schemas"]["SessionInfo"];
export type ParamValue = components["schemas"]["ParamValue"];
export type ParamEndRequest = components["schemas"]["ParamEndRequest"];
export type AuditItem = components["schemas"]["AuditItem"];
export type Product = components["schemas"]["Product"];
export type ProductSummary = components["schemas"]["ProductSummary"];
export type ProductVersion = components["schemas"]["ProductVersion"];
export type UserSummary = components["schemas"]["UserSummary"];
export type UserRoleGrant = components["schemas"]["UserRoleGrant"];
export type RoleSummary = components["schemas"]["RoleSummary"];
export type LoanSummary = components["schemas"]["LoanSummary"];
export type LoanList = components["schemas"]["LoanList"];
export type LoanStatus = LoanSummary["status"];
export type LoanDetail = components["schemas"]["LoanDetail"];
export type LoanInstallment = components["schemas"]["LoanInstallment"];
export type LoanScheduleVersion = components["schemas"]["LoanScheduleVersion"];
export type LoanDisbursementResult = components["schemas"]["LoanDisbursementResult"];
export type LoanPaymentResult = components["schemas"]["LoanPaymentResult"];
export type LoanRestructureResult = components["schemas"]["LoanRestructureResult"];
export type LoanWriteOffResult = components["schemas"]["LoanWriteOffResult"];
export type DepositAccount = components["schemas"]["DepositAccount"];
