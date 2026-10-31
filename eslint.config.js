// Lint statis TS/Svelte (T-057, D-139): `typescript-eslint` + aturan `svelte/*`.
//
// Satu kelompok aturan sengaja dimatikan, dengan alasan yang dicatat:
//
// - `svelte/a11y-*`: gate a11y sudah dipegang `svelte-check --fail-on-warnings` (D-053), dan
//   plugin ini hanya memetakan ulang diagnostik kompilator yang sama — menyalakannya berarti dua
//   gerbang untuk satu kebenaran, dengan pesan berbeda.
//
// `svelte/no-navigation-without-resolve` **aktif** sejak T-125: setiap tujuan navigasi internal
// lewat `resolve()` dari `$app/paths`, sehingga rute yang tidak ada ketahuan saat kompilasi (SPA
// statis di akar domain tanpa `paths.base` — `resolve()` tidak mengubah string, tapi mengikatnya
// ke daftar rute hasil generator).
//
// Berkas hasil generator tidak dilint: `paraglide` dan klien OpenAPI ditulis mesin, bukan tangan.
import svelte from "eslint-plugin-svelte";
import tseslint from "typescript-eslint";

const DISABLED_SVELTE_RULES = [/^svelte\/a11y-/];

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
    // `svelte-eslint-parser` meneruskan isi `<script lang="ts">` ke parser TS di sini. Informasi
    // tipe dari `tsconfig` terdekat dibutuhkan `svelte/no-navigation-without-resolve` untuk
    // mengenali href yang sudah di-resolve (`ResolvedPathname`); tanpa itu satu-satunya bentuk yang
    // diterima adalah panggilan `resolve()` langsung di tempat.
    files: ["**/*.svelte"],
    languageOptions: {
      parserOptions: {
        parser: tseslint.parser,
        projectService: true,
        extraFileExtensions: [".svelte"],
        tsconfigRootDir: import.meta.dirname,
      },
    },
  },
);
