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

/** Kelompok menu; urutannya tetap dan ditentukan di `navGroups`, bukan di urutan data. */
export type NavGroupId = "cash" | "members" | "ledger" | "admin";

export type NavGroup = {
  readonly id: NavGroupId;
  readonly label: (locale?: AppLocale) => string;
};

/**
 * Kelompok kerja (DESIGN §11: navigasi dikelompokkan menurut pekerjaan, bukan daftar datar).
 * Urutan di sini = urutan tampil; kelompok yang tidak punya tautan terlihat tidak dirender.
 */
export const navGroups: readonly NavGroup[] = [
  { id: "cash", label: (locale) => m.common_nav_group_cash({}, { locale }) },
  { id: "members", label: (locale) => m.common_nav_group_members({}, { locale }) },
  { id: "ledger", label: (locale) => m.common_nav_group_ledger({}, { locale }) },
  { id: "admin", label: (locale) => m.common_nav_group_admin({}, { locale }) },
];

export type NavLink = {
  /** Href internal (selalu di bawah `/app`). */
  readonly href: string;
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
export const appNavLinks: readonly NavLink[] = [
  {
    href: "/app/ledger",
    group: "ledger",
    label: (locale) => m.common_nav_ledger({}, { locale }),
    permissions: ["ledger.journal.read"],
  },
  {
    // Satu pintu untuk kerja admin buku besar (T-116). Izinnya `ledger.period.manage` supaya
    // pengguna baca-saja tidak melihatnya; seksi di dalam layar disaring sendiri oleh
    // `ledger.period.manage` / `ledger.coa.manage` / `ledger.journal.reverse`.
    href: "/app/ledger/admin",
    group: "ledger",
    label: (locale) => m.common_nav_ledger_admin({}, { locale }),
    permissions: ["ledger.period.manage"],
  },
  {
    href: "/app/teller",
    group: "cash",
    label: (locale) => m.common_nav_teller({}, { locale }),
    permissions: ["teller.transaction.post"],
  },
  {
    // Saldo kas vault + pengajuan/persetujuan top-up (T-121). Izin baca dipakai sebagai gerbang
    // menu; seksi pengajuan/keputusan disaring sendiri oleh `teller.vault.submit`/`approve`.
    href: "/app/vault",
    group: "cash",
    label: (locale) => m.common_nav_vault({}, { locale }),
    permissions: ["teller.vault.read"],
  },
  {
    // Monitor penutupan buku + aksi operator (T-139). Izin baca dipakai sebagai gerbang menu;
    // tombol Jalankan/Resume/Pause/Cancel disaring sendiri oleh `dayclose.run.manage`.
    href: "/app/dayclose",
    group: "ledger",
    label: (locale) => m.common_nav_dayclose({}, { locale }),
    permissions: ["dayclose.run.read"],
  },
  {
    href: "/app/accounts/open",
    group: "members",
    label: (locale) => m.common_nav_accounts({}, { locale }),
    permissions: ["deposit.account.manage"],
  },
  {
    href: "/app/params",
    group: "admin",
    label: (locale) => m.common_nav_params({}, { locale }),
    permissions: ["platform.param.read"],
  },
  {
    href: "/app/products",
    group: "admin",
    label: (locale) => m.common_nav_products({}, { locale }),
    permissions: ["product.catalog.read"],
  },
  {
    href: "/app/users",
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
 * Tautan yang terlihat, dikelompokkan. Kelompok kosong dibuang supaya pengguna tanpa izin
 * administrasi tidak melihat judul kelompok yang isinya nol tautan.
 */
export function groupVisibleLinks(links: readonly NavLink[]): Array<NavGroup & { links: NavLink[] }> {
  return navGroups
    .map((group) => ({ ...group, links: links.filter((link) => link.group === group.id) }))
    .filter((group) => group.links.length > 0);
}

/**
 * Tujuan pendaratan setelah masuk (login dan `/app`). Buku besar didahulukan bila boleh dibaca —
 * urutan menu adalah urutan kerja (kas lebih dulu), bukan urutan pendaratan. Pemakai tanpa izin
 * buku besar mendarat di tautan pertamanya, dan pemakai tanpa tautan sama sekali ke halaman kata
 * sandi (satu-satunya layar `/app` yang tidak butuh izin fitur).
 */
export function landingHref(links: readonly NavLink[]): string {
  return links.find((link) => link.href === "/app/ledger")?.href ?? links[0]?.href ?? "/app/password";
}

/**
 * `aria-current` menu. `/app` sendiri bukan tujuan menu (`+page.ts` mengalihkannya ke tujuan
 * pertama yang boleh dibuka), jadi cukup awalan rute.
 */
export function isActiveHref(currentPath: string, href: string): boolean {
  return currentPath === href || currentPath.startsWith(`${href}/`);
}
