/**
 * Sumber tunggal tautan navigasi area kerja `/app/*` (spec §14.3, T-110).
 *
 * Dipakai dua tempat: menu di `routes/+layout.svelte` dan command palette
 * (`routes/app/+layout.svelte`). Menambah halaman = menambah satu baris di sini, supaya daftar
 * tujuan tidak pernah berbeda antara menu dan palette — dan palette tidak perlu menyalin aturan
 * izin: halaman tujuan sendirilah yang menolak bila pemakainya tidak berhak (spec §13).
 *
 * Label disimpan sebagai **fungsi pesan** Paraglide, bukan string jadi: `label()` memakai bahasa
 * aktif, sedangkan `label("en")` dipakai pencarian lintas bahasa di palette.
 */

import * as m from "#lib/paraglide/messages.js";
import type { AppLocale } from "#lib/app/i18n.js";

export type NavLink = {
  /** Href internal (selalu di bawah `/app`). */
  readonly href: string;
  /** Label per locale; tanpa argumen = bahasa aktif. */
  readonly label: (locale?: AppLocale) => string;
};

/**
 * Urutan = urutan tab di menu (T-053: "Masuk" hanya di halaman publik, jadi tidak ada di sini).
 */
export const appNavLinks: readonly NavLink[] = [
  { href: "/app/ledger", label: (locale) => m.common_nav_ledger({}, { locale }) },
  { href: "/app/teller", label: (locale) => m.common_nav_teller({}, { locale }) },
  { href: "/app", label: (locale) => m.common_nav_params({}, { locale }) },
];

/**
 * `aria-current` menu: `/app` adalah halaman kerja itu sendiri, bukan awalan rute lain
 * (tanpa aturan ini, `/app/ledger` akan menyalakan dua tab sekaligus).
 */
export function isActiveHref(currentPath: string, href: string): boolean {
  if (href === "/app") return currentPath === "/app";
  return currentPath.startsWith(href);
}
