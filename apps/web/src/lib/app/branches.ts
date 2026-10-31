/**
 * Master cabang (`GET /api/v1/branches`). Dipakai layar yang perlu memilih cabang kerja sebelum
 * ada rekening anggota: vault (T-121) dan layar kas (T-141: buka kas tidak bergantung pada memuat
 * rekening). Izin `platform.branch.read` diperiksa server, bukan disaring di sini.
 */
import type { components } from "@kran/api-client/schema";

import { api } from "#lib/app/api.js";

export type Branch = components["schemas"]["BranchSummary"];

export function loadBranches() {
  return api.GET("/api/v1/branches");
}
