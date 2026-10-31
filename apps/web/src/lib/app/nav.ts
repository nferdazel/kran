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

import { resolve } from "$app/paths";
import type { ResolvedPathname } from "$app/types";

import * as m from "#lib/paraglide/messages.js";
import type { AppLocale } from "#lib/app/i18n.js";

/**
 * Tujuan tautan **yang sudah di-resolve** (T-125). Setiap entri `appNavLinks` memanggil `resolve()`
 * dari `$app/paths`, sehingga path yang tidak ada gagal saat `svelte-check` — bukan menjadi 404
 * yang baru ketahuan saat diklik. `svelte/no-navigation-without-resolve` menerimanya sebagai href
 * sah, jadi pemanggil tidak perlu (dan tidak boleh) me-resolve ulang.
 *
 * Unit test logika murni (`tests/unit`) menjalankan modul ini di Node tanpa plugin SvelteKit;
 * `vitest.config.ts` memetakan `$app/paths` ke stub yang mengembalikan path apa adanya (SPA di akar
 * domain, tanpa `paths.base`).
 */
export type NavHref = ResolvedPathname;

export type NavGroup = {
  readonly id: string;
  readonly label: (locale?: AppLocale) => string;
};

/**
 * Kelompok kerja (DESIGN §11: navigasi dikelompokkan menurut pekerjaan, bukan daftar datar).
 * Urutan di sini = urutan tampil; kelompok yang tidak punya tautan terlihat tidak dirender.
 * Id diambil dari daftar ini, bukan ditulis ulang sebagai union: menambah kelompok cukup di sini,
 * dan tautan yang lupa diberi kelompok ketahuan lewat test cakupan.
 */
export const navGroups = [
  { id: "cash", label: (locale) => m.common_nav_group_cash({}, { locale }) },
  { id: "members", label: (locale) => m.common_nav_group_members({}, { locale }) },
  { id: "ledger", label: (locale) => m.common_nav_group_ledger({}, { locale }) },
  { id: "admin", label: (locale) => m.common_nav_group_admin({}, { locale }) },
] as const satisfies readonly NavGroup[];

/** Kelompok menu; diturunkan dari `navGroups` supaya tidak bisa menyimpang. */
export type NavGroupId = (typeof navGroups)[number]["id"];

/**
 * Tautan navigasi dengan tujuan **sudah di-resolve** (T-125): path di `appNavLinks` bertipe
 * `ResolvedPathname` hasil generator SvelteKit, jadi rute yang tidak ada gagal saat kompilasi.
 *
 * `Href` dibiarkan sebagai parameter tipe (bawaan `string`) hanya supaya logika murni di sini bisa
 * diuji dengan path sintetis yang bukan rute nyata. Data produksi — `appNavLinks` di bawah —
 * mengikatnya ke `NavHref`, sehingga pemanggil (menu, palette, `landingHref`) menerima
 * `ResolvedPathname` dan tidak pernah me-resolve ulang.
 */
export type NavLink<Href extends string = string> = {
  /** Tujuan internal (selalu di bawah `/app`), sudah di-resolve. */
  readonly href: Href;
  /** Kelompok tempat tautan ini tampil. */
  readonly group: NavGroupId;
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
export const appNavLinks: readonly NavLink<NavHref>[] = [
  {
    href: resolve("/app/ledger"),
    group: "ledger",
    label: (locale) => m.common_nav_ledger({}, { locale }),
    permissions: ["ledger.journal.read"],
  },
  {
    // Satu pintu untuk kerja admin buku besar (T-116). Izinnya `ledger.period.manage` supaya
    // pengguna baca-saja tidak melihatnya; seksi di dalam layar disaring sendiri oleh
    // `ledger.period.manage` / `ledger.coa.manage` / `ledger.journal.reverse`.
    href: resolve("/app/ledger/admin"),
    group: "ledger",
    label: (locale) => m.common_nav_ledger_admin({}, { locale }),
    permissions: ["ledger.period.manage"],
  },
  {
    href: resolve("/app/teller"),
    group: "cash",
    label: (locale) => m.common_nav_teller({}, { locale }),
    permissions: ["teller.transaction.post"],
  },
  {
    // Saldo kas vault + pengajuan/persetujuan top-up (T-121). Izin baca dipakai sebagai gerbang
    // menu; seksi pengajuan/keputusan disaring sendiri oleh `teller.vault.submit`/`approve`.
    href: resolve("/app/vault"),
    group: "cash",
    label: (locale) => m.common_nav_vault({}, { locale }),
    permissions: ["teller.vault.read"],
  },
  {
    // Monitor penutupan buku + aksi operator (T-139). Izin baca dipakai sebagai gerbang menu;
    // tombol Jalankan/Resume/Pause/Cancel disaring sendiri oleh `dayclose.run.manage`.
    href: resolve("/app/dayclose"),
    group: "ledger",
    label: (locale) => m.common_nav_dayclose({}, { locale }),
    permissions: ["dayclose.run.read"],
  },
  {
    href: resolve("/app/accounts/open"),
    group: "members",
    label: (locale) => m.common_nav_accounts({}, { locale }),
    permissions: ["deposit.account.manage"],
  },
  {
    href: resolve("/app/params"),
    group: "admin",
    label: (locale) => m.common_nav_params({}, { locale }),
    permissions: ["platform.param.read"],
  },
  {
    href: resolve("/app/products"),
    group: "admin",
    label: (locale) => m.common_nav_products({}, { locale }),
    permissions: ["product.catalog.read"],
  },
  {
    href: resolve("/app/users"),
    group: "admin",
    label: (locale) => m.common_nav_users({}, { locale }),
    permissions: ["platform.user.manage"],
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
export function visibleNavLinks<Href extends string>(
  links: readonly NavLink<Href>[],
  permissions: readonly string[],
): NavLink<Href>[] {
  return links.filter(
    (link) =>
      link.permissions.length === 0 ||
      link.permissions.every((code) => permissions.includes(code)),
  );
}

/**
 * Tautan yang terlihat, dikelompokkan. Kelompok kosong dibuang supaya pengguna tanpa izin
 * administrasi tidak melihat judul kelompok yang isinya nol tautan.
 */
export function groupVisibleLinks<Href extends string>(
  links: readonly NavLink<Href>[],
): Array<NavGroup & { links: NavLink<Href>[] }> {
  return navGroups
    .map((group) => ({ ...group, links: links.filter((link) => link.group === group.id) }))
    .filter((group) => group.links.length > 0);
}

/**
 * Tujuan pendaratan setelah masuk, dipakai tiga jalur masuk (`/`, `/login`, `/app`) supaya
 * ketiganya tidak pernah menyimpang. Buku besar didahulukan karena ia rumah kerja pembukuan,
 * terlepas dari urutan tampil menu (yang dimulai dari kas). Pemakai tanpa izin buku besar
 * mendarat di tautan pertamanya; pemakai tanpa tautan sama sekali mendarat di layar parameter,
 * yang memang menampilkan penjelasan "tidak berizin" alih-alih memantulkan redirect.
 *
 * Kembaliannya tujuan yang sudah di-resolve milik tautan itu sendiri (atau path layar parameter
 * saat tidak ada tautan) — pemanggil tidak pernah me-resolve ulang.
 */
export function landingHref<Href extends string = NavHref>(
  links: readonly NavLink<Href>[],
): Href | NavHref {
  return (
    links.find((link) => link.href === "/app/ledger")?.href ??
    links[0]?.href ??
    resolve("/app/params")
  );
}

/**
 * `aria-current` menu. `/app` sendiri bukan tujuan menu (`+page.ts` mengalihkannya ke tujuan
 * pertama yang boleh dibuka), jadi cukup awalan rute.
 */
export function isActiveHref(currentPath: string, href: string): boolean {
  return currentPath === href || currentPath.startsWith(`${href}/`);
}
