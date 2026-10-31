/**
 * `/app` bukan tujuan: ia hanya pintu masuk. Tanpa aturan ini, pengguna yang mendarat di `/app`
 * melihat layar **parameter** apa pun izinnya — termasuk teller yang tidak boleh membacanya
 * (bug navigasi yang ditemukan audit UI/UX 31 Okt 2026). Tujuan dipilih dengan fungsi yang sama
 * dengan redirect setelah login, supaya keduanya tidak pernah menyimpang.
 */
import { redirect } from "@sveltejs/kit";

import { appNavLinks, landingHref, sessionPermissions, visibleNavLinks } from "#lib/app/nav.js";

export const load = async ({ parent }) => {
  const { session } = await parent();
  redirect(307, landingHref(visibleNavLinks(appNavLinks, sessionPermissions(session))));
};
