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
    }),
  ],
});
