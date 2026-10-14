/**
 * Klien API bersama (spec §13). `baseUrl` kosong = same-origin: permintaan jatuh ke `/api/...`
 * lewat proxy Vite/Caddy, sehingga cookie sesi `HttpOnly` ikut otomatis. Tidak ada token di JS.
 */
import { createCbsClient } from "@cbs/api-client";

export const api = createCbsClient();
