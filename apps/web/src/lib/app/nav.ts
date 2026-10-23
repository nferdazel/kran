/**
 * Sumber tunggal tautan navigasi area kerja `/app/*` (spec §14.3, T-110).
 *
 * Dipakai dua tempat: menu di `routes/+layout.svelte` dan command palette
 * (`routes/app/+layout.svelte`). Menambah halaman = menambah satu baris di sini, supaya daftar
 * tujuan tidak pernah berbeda antara menu dan palette.
 *
 * Setiap tautan membawa **kode izin** yang harus dipegang pemakainya (spec §13). Tautan tanpa izin
 * (daftar kosong) selalu tampil. Penyaringan dilakukan di satu fungsi murni (`visibleNavLinks`)
 * supaya menu dan palette tidak pernah menyalin aturan yang sama dua kali.
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
  /**
   * Kode izin yang harus dipegang pemakai agar tautan tampil (spec §13). Daftar kosong = tidak
   * butuh izin (selalu tampil); lebih dari satu = **semuanya** harus dipegang.
   */
  readonly permissions: readonly string[];
};

/**
 * Urutan = urutan tab di menu (T-053: "Masuk" hanya di halaman publik, jadi tidak ada di sini).
 */
export const appNavLinks: readonly NavLink[] = [
  {
    href: "/app/ledger",
    label: (locale) => m.common_nav_ledger({}, { locale }),
    permissions: ["ledger.journal.read"],
  },
  {
    // Satu pintu untuk kerja admin buku besar (T-116). Izinnya `ledger.period.manage` supaya
    // pengguna baca-saja tidak melihatnya; seksi di dalam layar disaring sendiri oleh
    // `ledger.period.manage` / `ledger.coa.manage` / `ledger.journal.reverse`.
    href: "/app/ledger/admin",
    label: (locale) => m.common_nav_ledger_admin({}, { locale }),
    permissions: ["ledger.period.manage"],
  },
  {
    href: "/app/teller",
    label: (locale) => m.common_nav_teller({}, { locale }),
    permissions: ["teller.transaction.post"],
  },
  {
    href: "/app/accounts/open",
    label: (locale) => m.common_nav_accounts({}, { locale }),
    permissions: ["deposit.account.manage"],
  },
  {
    href: "/app",
    label: (locale) => m.common_nav_params({}, { locale }),
    permissions: ["platform.param.read"],
  },
  {
    href: "/app/products",
    label: (locale) => m.common_nav_products({}, { locale }),
    permissions: ["product.catalog.read"],
  },
];

/**
 * Izin sesi dalam bentuk daftar; `null`/`undefined` (mis. saat data sesi belum termuat) = kosong,
 * sehingga tautan berizin **disembunyikan** (fail-closed), bukan ditampilkan optimistis.
 */
export function sessionPermissions(
  session: { readonly permissions?: readonly string[] } | null | undefined,
): readonly string[] {
  return Array.isArray(session?.permissions) ? session.permissions : [];
}

/** Saring tautan: hanya izin yang **tidak** dibutuhkan atau seluruh izinnya dipegang pemakai. */
export function visibleNavLinks(
  links: readonly NavLink[],
  permissions: readonly string[],
): NavLink[] {
  return links.filter(
    (link) =>
      link.permissions.length === 0 ||
      link.permissions.every((code) => permissions.includes(code)),
  );
}

/**
 * `aria-current` menu: `/app` adalah halaman kerja itu sendiri, bukan awalan rute lain
 * (tanpa aturan ini, `/app/ledger` akan menyalakan dua tab sekaligus).
 */
export function isActiveHref(currentPath: string, href: string): boolean {
  if (href === "/app") return currentPath === "/app";
  return currentPath.startsWith(href);
}
