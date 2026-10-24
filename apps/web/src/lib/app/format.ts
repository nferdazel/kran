/**
 * Format angka/tanggal/uang (spec §16.2): `Intl` dengan locale aktif.
 *
 * Uang dari API datang sebagai **string desimal** 2 desimal (spec §13, D-136), bukan number JSON —
 * jadi fungsi ini menerima string dan hanya mengubahnya untuk *tampilan*.
 */

import * as m from "#lib/paraglide/messages.js";
import { formatMoney as formatMoneyForLocale, type MoneyDecimals } from "@kran/ui/money";
import { currentLocale } from "#lib/app/i18n.js";

/**
 * Uang dari API datang sebagai **string desimal** (spec §13: `"1500000.00"`), bukan number JSON.
 * `formatMoney` (T-083/D-136) mempertahankan presisi tanpa float dan tanpa simbol mata uang:
 * simbol ditaruh di judul kolom (DESIGN §6).
 */
export function formatMoney(decimal: string, options: { decimals?: MoneyDecimals } = {}): string {
  return formatMoneyForLocale(decimal, {
    locale: currentLocale(),
    decimals: options.decimals ?? 2,
  });
}

/**
 * Jamak (spec §16.2). Paraglide v2 **tidak** menafsirkan sintaks ICU mentah
 * (`{n, plural, …}`) — string-nya rusak menjadi placeholder saat kompilasi (terbukti pada
 * `packages/i18n/messages`, lihat docs/tasks/T-010.md). Karena itu bentuk jamak dipilih di kode
 * dengan `Intl.PluralRules`, dan katalog menyediakan satu pesan per bentuk.
 */
export function formatAccountCount(count: number): string {
  if (count === 0) {
    return m.common_home_accounts_none();
  }
  const category = new Intl.PluralRules(currentLocale()).select(count);
  return category === "one" ? m.common_home_accounts_one({ count }) : m.common_home_accounts_other({ count });
}

/**
 * Tanggal bisnis (`YYYY-MM-DD`) → teks locale aktif.
 *
 * `timeZone: "UTC"` wajib (T-132/UI-6): nilainya dibangun sebagai tengah malam UTC, jadi tanpa
 * opsi itu peramban di zona negatif (mis. Amerika) menampilkannya sebagai **hari sebelumnya** —
 * tanggal bisnis yang salah baca pada laporan dan slip. Tanggal bisnis adalah tanggal kalender,
 * bukan instan waktu: ia tidak boleh "bergeser" mengikuti zona perangkat.
 *
 * Zona waktu per cabang (WIB/WITA/WIT, spec §16.2) **belum** ditangani di sini. Saat itu datang,
 * tanggal harus dibangun sebagai tengah malam di zona cabang (bukan tengah malam UTC yang
 * diformat dengan zona lain — itu justru menggeser hasilnya).
 */
export function formatDate(isoDate: string): string {
  const [year, month, day] = isoDate.split("-").map(Number);
  if (!year || !month || !day) {
    throw new Error(`tanggal bukan ISO YYYY-MM-DD: ${isoDate}`);
  }
  return new Intl.DateTimeFormat(currentLocale(), { dateStyle: "long", timeZone: "UTC" }).format(
    new Date(Date.UTC(year, month - 1, day)),
  );
}

/** Waktu ISO-8601 UTC (mis. `recordedAt` audit) → tampilan tanggal + jam locale aktif. */
export function formatDateTime(iso: string): string {
  const value = new Date(iso);
  if (Number.isNaN(value.getTime())) {
    return iso;
  }
  return new Intl.DateTimeFormat(currentLocale(), {
    dateStyle: "medium",
    timeStyle: "medium",
  }).format(value);
}

/** Jam locale aktif (indikator realtime). */
export function formatClock(at: Date): string {
  return new Intl.DateTimeFormat(currentLocale(), { timeStyle: "medium" }).format(at);
}
