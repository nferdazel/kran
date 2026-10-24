import { defineConfig } from "vitest/config";

// Unit test logika web (T-126): fungsi murni di `src/lib/app`, tanpa DOM dan tanpa jaringan.
// Dijalankan `./task e2e`/`./task ci`; `pnpm --filter @kran/web test` untuk loop lokal.
export default defineConfig({
  test: {
    include: ["tests/unit/**/*.test.ts"],
    environment: "node",
  },
});
