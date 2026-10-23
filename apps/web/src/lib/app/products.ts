/**
 * Glue layar katalog produk: pemetaan peserta tipe produk, penolakan domain versi, dan pengumpulan
 * versi `DRAFT`. Logika murni (tanpa DOM, tanpa jaringan) supaya bisa diuji vitest.
 *
 * Catatan kontrak (per 23 Okt 2026):
 *  - `GET /api/v1/products` hanya memuat versi `ACTIVE`; versi `DRAFT`/`REJECTED` tidak pernah
 *    muncul di katalog, sehingga approval membutuhkan `GET /api/v1/products/{code}` per produk.
 *  - `POST .../approve` dan `POST .../reject` menandai sebab kegagalan lewat `params.reason`
 *    (`self_approval`, `not_draft`, `window_conflict`, `no_bindings`, `reason_missing`,
 *    `reason_too_long`). Karena itu pemetaannya per `reason`, bukan lewat `i18nKey` (pola
 *    `paramProblemMessage` di `errors.ts`).
 */

import type { Problem } from "@kran/api-client";

import * as m from "#lib/paraglide/messages.js";
import { problemMessage } from "#lib/app/errors.js";
import type { Product, ProductSummary, ProductVersion } from "#lib/app/types.js";

const REASON_MESSAGES: Record<string, () => string> = {
  self_approval: () => m.products_error_self_approval(),
  not_draft: () => m.products_error_not_draft(),
  window_conflict: () => m.products_error_window_conflict(),
  no_bindings: () => m.products_error_no_bindings(),
  reason_missing: () => m.products_error_reason_missing(),
  reason_too_long: () => m.products_error_reason_too_long(),
};

/** Pesan kegagalan versi produk; sebab tak dikenal jatuh kembali ke pesan amplop. */
export function productProblemMessage(problem: Problem): string {
  const reason = problem.params?.reason;
  const template = reason === undefined ? undefined : REASON_MESSAGES[reason];
  return template === undefined ? problemMessage(problem) : template();
}

export function productTypeLabel(type: ProductSummary["productType"]): string {
  if (type === "SAVINGS") return m.products_type_savings();
  if (type === "TIME_DEPOSIT") return m.products_type_time_deposit();
  if (type === "LOAN") return m.products_type_loan();
  return m.products_type_financing();
}

export type DraftVersion = {
  readonly product: ProductSummary;
  readonly version: ProductVersion;
};

/**
 * Satukan daftar ringkas dengan detail per produk (paralel: indeks sama) menjadi versi `DRAFT`.
 * Detail yang null (gagal dimuat per produk) dilewati, bukan menggagalkan seluruh layar.
 */
export function draftVersionsOf(
  products: readonly ProductSummary[],
  details: readonly (Product | null)[],
): DraftVersion[] {
  const drafts: DraftVersion[] = [];
  products.forEach((product, index) => {
    const detail = details[index];
    if (detail === null || detail === undefined) return;
    for (const version of detail.versions) {
      if (version.status === "DRAFT") drafts.push({ product, version });
    }
  });
  return drafts;
}
