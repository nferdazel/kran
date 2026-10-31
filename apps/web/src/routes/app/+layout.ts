// Guard sesi untuk seluruh rute di bawah `/app` (spec §13, §18.2): cookie sesi dibuktikan ke server
// sebelum halaman kerja dirender. 401 → kembali ke `/login`. `ssr = false` di layout akar, jadi
// `load` ini berjalan di browser dan cookie `HttpOnly` ikut terkirim (same-origin lewat proxy —
// D-025).
//
// Tiga aturan yang berlaku di semua rute kerja:
//   1. tanpa sesi sah → `/login`;
//   2. sesi yang masih wajib ganti kata sandi (admin pertama hasil `ctl bootstrap-admin`, T-027)
//      → `/app/password`, kecuali memang sudah di sana. Server tetap menolak operasi lain
//      (403 `password_change_required`); ini yang membuat pengguna tidak terjebak melihat galat.
//   3. tanggal bisnis institusi hanya diambil bila sesi memegang `dayclose.run.read`; tanpa izin
//      itu shell tidak menampilkan indikator apa pun (tidak ada tanggal karangan).
import { redirect } from "@sveltejs/kit";

import { api } from "#lib/app/api.js";

const PASSWORD_PATH = "/app/password";
const DAYCLOSE_READ = "dayclose.run.read";

export const load = async ({ url }) => {
  const { data, response } = await api.GET("/api/v1/auth/session");
  if (!response.ok || !data) redirect(303, "/login");

  if (data.mustChangePassword && url.pathname !== PASSWORD_PATH) {
    redirect(303, PASSWORD_PATH);
  }

  // `null` = nilai diketahui kosong (institusi belum punya baris tanggal buku); `undefined` =
  // tidak tahu (izin tidak ada atau permintaan gagal). Shell hanya menampilkan indikator pada
  // kasus kedua-duanya yang jujur: tanggal nyata, atau "belum tersedia" yang memang keadaan.
  let businessDate: string | null | undefined;
  if ((data.permissions ?? []).includes(DAYCLOSE_READ)) {
    const status = await api.GET("/api/v1/dayclose/status");
    if (status.response.ok) {
      // `businessDate` bukan string: objek `{ date, state, frozenAt }` (lihat kontrak).
      businessDate = status.data?.businessDate?.date ?? null;
    }
  }

  return { session: data, businessDate };
};
