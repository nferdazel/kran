import { paraglideVitePlugin } from "@inlang/paraglide-js";
import adapter from "@sveltejs/adapter-static";
import { sveltekit } from "@sveltejs/kit/vite";
import { defineConfig } from "vite";

/**
 * Konfigurasi aplikasi web (spec §14.1):
 *  - SvelteKit 3: konfigurasi Kit lewat plugin `sveltekit()` (berkas `svelte.config.js` sudah
 *    tidak dipakai lagi oleh Kit 3 — terverifikasi saat build: `config_file_unsupported`).
 *  - **SPA**: `adapter-static` + `fallback: "index.html"`, SSR dimatikan di `src/routes/+layout.ts`.
 *  - Katalog pesan hidup di `packages/i18n/messages` (spec §16.2); Paraglide mengompilasinya ke
 *    `src/lib/paraglide` (dihasilkan, tidak di-commit).
 *  - `emitTsDeclarations` penting: tanpa itu tidak ada `.d.ts`, sehingga `svelte-check` kehilangan
 *    jaminan "key pesan bertipe" yang jadi alasan memilih Paraglide (spec §14.1/§16.2).
 */
/**
 * Proxy API (dev `vite` maupun `vite preview` Playwright) — spec §14.1: tanpa proxy, cookie
 * sesi `SameSite=Strict` tidak akan ikut terkirim karena halaman di origin Vite dan API di
 * origin lain. Lewat proxy semua jadi same-origin; `ws: true` meneruskan upgrade WebSocket
 * `/api/v1/events/stream` (spec §19.3).
 *
 * Port API dev default 8080; Playwright menimpanya lewat `KRAN_API_TARGET` ke port e2e 8099
 * (playwright.config.ts) supaya tidak bentrok dengan API dev yang sedang berjalan.
 */
const apiTarget = process.env.KRAN_API_TARGET ?? "http://127.0.0.1:8080";
const proxy = {
  "/api": { target: apiTarget, changeOrigin: false, ws: true },
  "/healthz": { target: apiTarget, changeOrigin: false },
  "/readyz": { target: apiTarget, changeOrigin: false },
};

export default defineConfig({
  plugins: [
    paraglideVitePlugin({
      project: "../../packages/i18n/project.inlang",
      outdir: "./src/lib/paraglide",
      strategy: ["localStorage", "preferredLanguage", "baseLocale"],
      emitTsDeclarations: true,
    }),
    sveltekit({
      adapter: adapter({ fallback: "index.html" }),
      /**
       * CSP (spec §21.5, O-061). Halaman di-prerender (`fallback: index.html`), jadi Kit memakai
       * **hash** dan menuliskannya ke `<meta http-equiv="content-security-policy">` — nonce tidak
       * boleh untuk halaman prerender. Header Caddy memuat kebijakan yang sama; browser menerapkan
       * irisan keduanya, sehingga `script-src 'self'` di header + hash di meta = hanya script milik
       * aplikasi (tanpa `'unsafe-inline'`) yang boleh jalan.
       */
      csp: {
        mode: "hash",
        directives: {
          "default-src": ["self"],
          "script-src": ["self"],
          "style-src": ["self", "unsafe-inline"], // Svelte menyuntik <style> saat runtime
          "img-src": ["self", "data:"],
          "connect-src": ["self"], // termasuk SSE /api/v1/events/stream (same-origin)
          "base-uri": ["self"],
          "form-action": ["self"],
          "object-src": ["none"],
        },
      },
    }),
  ],
  server: { proxy },
  preview: { proxy },
});
