/**
 * Kebijakan kata sandi yang berlaku (O-051). Angkanya dibaca dari parameter institusi lewat
 * `GET /api/v1/auth/password-policy`, bukan ditulis di UI: kalau admin mengubah panjang minimum,
 * layar ganti sandi harus ikut tanpa rilis ulang.
 */
import type { components } from "@kran/api-client/schema";

import * as m from "#lib/paraglide/messages.js";
import { api } from "#lib/app/api.js";

export type PasswordPolicy = components["schemas"]["PasswordPolicy"];

export function loadPasswordPolicy() {
  return api.GET("/api/v1/auth/password-policy");
}

/** Kalimat aturan untuk ditampilkan. Gagal memuat = pemanggil tetap memakai petunjuk statis. */
export function policyHint(policy: PasswordPolicy): string {
  return m.password_hint_policy({
    minLength: policy.minLength,
    minClasses: policy.minClasses,
    historyCount: policy.historyCount,
  });
}
