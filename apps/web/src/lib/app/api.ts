/**
 * Klien API bersama (spec §13). `baseUrl` kosong = same-origin: permintaan jatuh ke `/api/...`
 * lewat proxy Vite/Caddy, sehingga cookie sesi `HttpOnly` ikut otomatis. Tidak ada token di JS.
 *
 * Satu aturan lintas layar di sini: **401 → `/login`** (T-132/UI-5). Sebelumnya setiap layar
 * menangani galatnya sendiri, jadi sesi yang kedaluwarsa meninggalkan formulir interaktif yang
 * setiap kirimannya gagal tanpa jalan keluar. Penanganannya di transport, bukan di tiap komponen:
 * satu tempat, dan layar baru otomatis ikut.
 */
import { createKranClient } from "@kran/api-client";

export const LOGIN_PATH = "/login";

/**
 * Apakah respons ini berarti sesi berakhir (bukan kredensial salah)? Di halaman masuk sendiri
 * 401 adalah jawaban normal untuk kata sandi salah, jadi tidak boleh memicu pengalihan.
 */
export function shouldRedirectToLogin(status: number, pathname: string): boolean {
  return status === 401 && !pathname.startsWith(LOGIN_PATH);
}

export const api = createKranClient();

// Bentuk middleware mengikuti tipe `api.use` (tidak mengimpor `openapi-fetch` langsung: paket itu
// milik `@kran/api-client`, bukan dependency layar web).
api.use({
  onResponse({ response }) {
    if (typeof window === "undefined") return response;
    if (shouldRedirectToLogin(response.status, window.location.pathname)) {
      // Muat ulang penuh, bukan navigasi klien: setelah sesi hilang, seluruh state di memori
      // (izin, langganan realtime, data halaman) sudah tidak berlaku.
      window.location.assign(LOGIN_PATH);
    }
    return response;
  },
});
