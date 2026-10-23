/**
 * Logika command palette (T-110, spec §14.3): daftar aksi, pencarian, tanpa DOM.
 *
 * **Aksi = navigasi**, bukan perintah yang mengubah data: sumber daftarnya adalah nav yang sudah
 * ada (`nav.ts`), jadi palette tidak memperkenalkan jalan masuk kedua ke operasi bisnis dan tidak
 * menggandakan aturan izin — halaman tujuan tetap yang menolak bila pemakainya tidak berhak.
 *
 * Pencarian = substring tanpa peduli huruf besar/kecil atas label **semua locale** + href, supaya
 * "buku besar" (id) dan "ledger" (en) sama-sama menemukan `/app/ledger` tanpa bergantung bahasa UI.
 */

import type { AppLocale } from "#lib/app/i18n.js";

export type PaletteSource = {
  readonly href: string;
  readonly label: (locale?: AppLocale) => string;
};

export type PaletteAction = {
  readonly href: string;
  /** Label bahasa aktif (yang ditampilkan). */
  readonly label: string;
  /** Kata kunci pencarian (huruf kecil, unik): label tiap locale + href. */
  readonly keywords: readonly string[];
};

/** Susun aksi dari sumber nav untuk locale aktif; kata kunci mencakup seluruh locale. */
export function paletteActions(
  sources: readonly PaletteSource[],
  locale: AppLocale,
  locales: readonly AppLocale[],
): PaletteAction[] {
  return sources.map((source) => {
    const keywords = [source.href, ...locales.map((each) => source.label(each))].map((term) =>
      term.toLowerCase(),
    );
    return { href: source.href, label: source.label(locale), keywords: [...new Set(keywords)] };
  });
}

/** Saring aksi; kueri kosong = seluruh daftar (urutan sumber dipertahankan). */
export function filterActions(
  actions: readonly PaletteAction[],
  query: string,
): PaletteAction[] {
  const needle = query.trim().toLowerCase();
  if (needle === "") return [...actions];
  return actions.filter((action) =>
    action.keywords.some((keyword) => keyword.includes(needle)),
  );
}
