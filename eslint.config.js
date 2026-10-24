// Lint statis TS/Svelte (T-057, D-139): `typescript-eslint` + aturan `svelte/*`.
//
// Dua kelompok aturan sengaja dimatikan, dengan alasan yang dicatat:
//
// - `svelte/a11y-*`: gate a11y sudah dipegang `svelte-check --fail-on-warnings` (D-053), dan
//   plugin ini hanya memetakan ulang diagnostik kompilator yang sama — menyalakannya berarti dua
//   gerbang untuk satu kebenaran, dengan pesan berbeda.
// - `svelte/no-navigation-without-resolve`: menuntut `resolve()` dari `$app/paths` bertipe rute.
//   Aplikasi ini SPA statis di akar domain tanpa `paths.base`, jadi `resolve()` tidak mengubah
//   apa pun; mengadopsinya berarti menyentuh 21 titik navigasi + tipe data nav/palette. Itu
//   migrasi UI tersendiri (T-125), bukan bagian dari pemasangan lint.
//
// Berkas hasil generator tidak dilint: `paraglide` dan klien OpenAPI ditulis mesin, bukan tangan.
import svelte from "eslint-plugin-svelte";
import tseslint from "typescript-eslint";

const DISABLED_SVELTE_RULES = [/^svelte\/a11y-/, /^svelte\/no-navigation-without-resolve$/];

const filtered = (config) =>
  config.rules
    ? {
        ...config,
        rules: Object.fromEntries(
          Object.entries(config.rules).filter(
            ([rule]) => !DISABLED_SVELTE_RULES.some((pattern) => pattern.test(rule)),
          ),
        ),
      }
    : config;

export default tseslint.config(
  {
    ignores: [
      "**/node_modules/**",
      "**/.svelte-kit/**",
      "**/build/**",
      "**/dist/**",
      "apps/web/src/lib/paraglide/**",
      "packages/api-client/src/generated/**",
    ],
  },
  ...tseslint.configs.recommended,
  ...svelte.configs.recommended.map(filtered),
  {
    // `svelte-eslint-parser` meneruskan isi `<script lang="ts">` ke parser TS di sini.
    files: ["**/*.svelte"],
    languageOptions: { parserOptions: { parser: tseslint.parser } },
  },
);
