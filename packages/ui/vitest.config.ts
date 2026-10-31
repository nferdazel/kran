// Test `packages/ui` (DESIGN §12 fase 1): token kontras + uang + komponen Svelte (SSR).
//
// Komponen diuji lewat `render` dari `svelte/server`, bukan DOM: tidak ada jsdom/testing-library
// (dependensi baru butuh ADR). Karena itu `.svelte` dikompilasi plugin resmi Svelte dan vitest
// berjalan di `environment: "node"`.
import { svelte } from "@sveltejs/vite-plugin-svelte";
import { defineConfig } from "vitest/config";

export default defineConfig({
  plugins: [svelte()],
  test: {
    include: ["tests/**/*.test.ts"],
    environment: "node",
  },
});
