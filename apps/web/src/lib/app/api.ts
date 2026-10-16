/**
 * Klien API bersama (spec §13). `baseUrl` kosong = same-origin: permintaan jatuh ke `/api/...`
 * lewat proxy Vite/Caddy, sehingga cookie sesi `HttpOnly` ikut otomatis. Tidak ada token di JS.
 */
import { createKranClient } from "@kran/api-client";

export const api = createKranClient();
