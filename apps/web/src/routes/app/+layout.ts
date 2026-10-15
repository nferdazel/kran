// Guard sesi untuk seluruh rute di bawah `/app` (spec §13, §18.2): cookie sesi dibuktikan ke server
// sebelum halaman kerja dirender. 401 → kembali ke `/login`. `ssr = false` di layout akar, jadi
// `load` ini berjalan di browser dan cookie `HttpOnly` ikut terkirim (same-origin lewat proxy —
// D-025).
//
// Satu tempat untuk dua aturan yang berlaku di semua rute kerja:
//   1. tanpa sesi sah → `/login`;
//   2. sesi yang masih wajib ganti kata sandi (admin pertama hasil `ctl bootstrap-admin`, T-027)
//      → `/app/password`, kecuali memang sudah di sana. Server tetap menolak operasi lain
//      (403 `password_change_required`); ini yang membuat pengguna tidak terjebak melihat galat.
import { redirect } from "@sveltejs/kit";

import { api } from "#lib/app/api.js";

const PASSWORD_PATH = "/app/password";

export const load = async ({ url }) => {
  const { data, response } = await api.GET("/api/v1/auth/session");
  if (!response.ok || !data) redirect(303, "/login");

  if (data.mustChangePassword && url.pathname !== PASSWORD_PATH) {
    redirect(303, PASSWORD_PATH);
  }
  return { session: data };
};
