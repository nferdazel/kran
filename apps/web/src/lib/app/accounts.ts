/**
 * Glue layar buka rekening simpanan (T-115): klien pencarian party + buka rekening, penyaringan
 * produk, dan pemetaan galat domain. Logika murni (penyaringan, pemetaan pesan, label status)
 * dipisah dari komponen supaya bisa diuji vitest tanpa DOM dan tanpa DB.
 *
 * Catatan kontrak (per 23 Okt 2026):
 *  - `GET /parties?query=` mengembalikan bentuk **ringkas** (`PartySummary`, tanpa KYC) dan
 *    mensyaratkan `query` minimal 2 karakter; `limit`/`branchId` opsional.
 *  - `GET /products` hanya memuat versi `ACTIVE`; `currentVersion` null berarti tidak ada versi
 *    yang berlaku, jadi produk itu tidak bisa dipilih.
 *  - `POST /deposit/accounts` mewajibkan `Idempotency-Key`. Konflik domain 409 membawa
 *    `params.reason` (`party_not_active`, `branch_mismatch`, `product_not_active`,
 *    `branch_not_registered`), jadi pemetaannya per `reason` (pola
 *    `productProblemMessage`/`tellerProblemMessage`).
 */

import type { Problem } from "@kran/api-client";
import type { components } from "@kran/api-client/schema";

import * as m from "#lib/paraglide/messages.js";
import { api } from "#lib/app/api.js";
import { problemMessage } from "#lib/app/errors.js";

export type PartySummary = components["schemas"]["PartySummary"];
export type ProductSummary = components["schemas"]["ProductSummary"];
export type DepositAccount = components["schemas"]["DepositAccount"];

/** Minimal karakter `query` yang diterima server; di sini untuk membatasi pencarian dari UI. */
export const MIN_PARTY_QUERY_LENGTH = 2;

/**
 * Produk yang boleh dipilih untuk rekening baru: berjenis `SAVINGS` **dan** punya versi `ACTIVE`
 * berlaku (`currentVersion` tidak null). Produk tanpa versi aktif tidak ditawarkan supaya pengguna
 * tidak menabrak 409 `product_not_active`.
 */
export function savingsProducts(products: readonly ProductSummary[]): ProductSummary[] {
  return products.filter(
    (product) => product.productType === "SAVINGS" && product.currentVersion !== null,
  );
}

const PARTY_STATUS_MESSAGES: Record<string, () => string> = {
  ACTIVE: () => m.accounts_status_active(),
  SUSPENDED: () => m.accounts_status_suspended(),
  CLOSED: () => m.accounts_status_closed(),
};

/** Label status party (daftar hasil pencarian). Nilai di luar tiga status kontrak ditampilkan apa
 * adanya, bukan diterjemahkan menjadi status yang tidak dikirim server. */
export function partyStatusLabel(status: PartySummary["status"]): string {
  const template = PARTY_STATUS_MESSAGES[status];
  return template === undefined ? status : template();
}

const OPEN_REASON_MESSAGES: Record<string, () => string> = {
  party_not_active: () => m.accounts_error_party_not_active(),
  branch_mismatch: () => m.accounts_error_branch_mismatch(),
  product_not_active: () => m.accounts_error_product_not_active(),
  branch_not_registered: () => m.accounts_error_branch_not_registered(),
};

/**
 * Pesan galat buka rekening. Urutan: `params.reason` (409/403 domain), lalu 403 izin, terakhir
 * amplop `problemMessage` biasa. Cause tak dikenal tidak ditebak.
 */
export function accountOpenProblemMessage(problem: Problem): string {
  const reason = problem.params?.reason;
  const template = reason === undefined ? undefined : OPEN_REASON_MESSAGES[reason];
  if (template !== undefined) return template();
  if (problem.status === 403) return m.accounts_error_forbidden();
  return problemMessage(problem);
}

/** Pencarian party ringkas; `branchId` opsional (izin harus dipegang di cabang itu). */
export function searchParties(query: string, branchId?: string) {
  return api.GET("/api/v1/parties", {
    params: { query: branchId === undefined ? { query } : { query, branchId } },
  });
}

export function openDepositAccount(
  body: { partyId: string; productCode: string; branchId: string },
  idempotencyKey: string,
) {
  return api.POST("/api/v1/deposit/accounts", {
    params: { header: { "Idempotency-Key": idempotencyKey } },
    body,
  });
}
