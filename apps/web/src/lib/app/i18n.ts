/**
 * Glue i18n (spec §16). Katalog pesan dikompilasi Paraglide dari `packages/i18n/messages`.
 *
 * Bahasa tidak disimpan di server pada Fase 0 (belum ada profil pengguna di UI); Paraglide
 * menyimpannya di `localStorage` lewat strategi `["localStorage", "preferredLanguage", "baseLocale"]`
 * yang diset di `vite.config.ts`.
 *
 * Catatan reaktivitas: fungsi pesan Paraglide membaca state runtime (bukan store Svelte), jadi
 * komponen membungkus isinya dengan `{#key locale}` — ganti bahasa mem-bangun ulang subtree dan
 * semua pesan dirender dengan bahasa baru. Ini pilihan sadar: lebih sederhana daripada menyalin
 * tiap pesan ke store, dan tidak ada state aplikasi yang perlu dipertahankan pada shell Fase 0.
 */

import { getLocale, setLocale, locales as paraglideLocales, type Locale } from "#lib/paraglide/runtime.js";

export type AppLocale = Locale;

/** Locale aplikasi (spec §16.1): `id` default, `en`. */
export const supportedLocales: readonly AppLocale[] = paraglideLocales;

export function currentLocale(): AppLocale {
  return getLocale();
}

export function normalizeLocale(value: string | null | undefined): AppLocale {
  return supportedLocales.includes(value as AppLocale) ? (value as AppLocale) : "id";
}

/** Terapkan bahasa + atribut `lang` di `<html>` (spec §17.1). */
export async function switchLocale(locale: AppLocale): Promise<void> {
  await setLocale(locale, { reload: false });
  document.documentElement.lang = locale;
}

/** Sinkronkan `lang` dengan bahasa aktif saat halaman dibuka. */
export function syncDocumentLanguage(): AppLocale {
  const locale = currentLocale();
  document.documentElement.lang = locale;
  return locale;
}
