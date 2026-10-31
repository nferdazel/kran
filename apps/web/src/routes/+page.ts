// Beranda = tempat kerja, bukan halaman pemasaran. Tanpa sesi → masuk; dengan sesi → tujuan
// pendaratan yang sama dengan `/app` dan redirect setelah login (satu fungsi, `landingHref`).
// `ssr = false` di layout akar, jadi pemeriksaan ini berjalan di browser dan cookie HttpOnly ikut.
import { redirect } from "@sveltejs/kit";

import { api } from "#lib/app/api.js";
import { appNavLinks, landingHref, sessionPermissions, visibleNavLinks } from "#lib/app/nav.js";

export const load = async () => {
  const { data, response } = await api.GET("/api/v1/auth/session");
  if (!response.ok || !data) redirect(303, "/login");
  redirect(303, landingHref(visibleNavLinks(appNavLinks, sessionPermissions(data))));
};
