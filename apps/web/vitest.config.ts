import { defineConfig } from "vitest/config";

// Unit test logika web (T-126): fungsi murni di `src/lib/app`, tanpa DOM dan tanpa jaringan.
// Dijalankan `./task e2e`/`./task ci`; `pnpm --filter @kran/web test` untuk loop lokal.
//
// `$app/paths` hanya ada di build SvelteKit; `nav.ts` memakainya untuk `resolve()` (T-125), jadi
// test node memakai stub yang mengembalikan path apa adanya (SPA tanpa `paths.base`).
export default defineConfig({
  resolve: {
    alias: {
      "$app/paths": new URL("./tests/unit/stubs/app-paths.ts", import.meta.url).pathname,
    },
  },
  test: {
    include: ["tests/unit/**/*.test.ts"],
    environment: "node",
  },
});
