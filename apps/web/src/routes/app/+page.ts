// Guard sesi (spec §13, §18.2): `/app` hanya boleh dibuka setelah cookie sesi terbukti sah lewat
// server. 401 → kembali ke `/login`. `ssr = false` di layout induk, jadi `load` ini berjalan di
// browser dan cookie `HttpOnly` ikut terkirim (same-origin lewat proxy — D-025).
import { redirect } from "@sveltejs/kit";

import { api } from "#lib/app/api.js";

export const load = async () => {
  const { data, response } = await api.GET("/api/v1/auth/session");
  if (!response.ok || !data) redirect(303, "/login");
  return { session: data };
};
