/**
 * Stub `$app/paths` untuk unit test node (T-125).
 *
 * `nav.ts` memakai `resolve()` supaya setiap tujuan menu diperiksa terhadap daftar rute hasil
 * generator saat `svelte-check`. Unit test menjalankan modul itu di Node tanpa plugin SvelteKit,
 * jadi modul ini menggantikannya saat test — SPA ini di akar domain tanpa `paths.base`, sehingga
 * `resolve()` memang mengembalikan path apa adanya.
 */

export function resolve(path: string): string {
  return path;
}

export function asset(path: string): string {
  return path;
}

export const base = "";
