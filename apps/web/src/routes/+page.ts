// Beranda = tempat kerja, bukan halaman pemasaran. Tanpa sesi → masuk; dengan sesi → buku besar.
// `ssr = false` di layout akar, jadi pemeriksaan ini berjalan di browser dan cookie HttpOnly ikut.
import { redirect } from "@sveltejs/kit";

import { api } from "#lib/app/api.js";

export const load = async () => {
  const { response } = await api.GET("/api/v1/auth/session");
  redirect(303, response.ok ? "/app/ledger" : "/login");
};
