/**
 * Format uang dari string desimal (spec §13, DESIGN §6, D-097).
 *
 * Kenapa tidak memakai `Number`: uang tidak boleh melewati float. Semua langkah di sini bekerja
 * pada string dan `BigInt`, termasuk pembulatan half-even, jadi nilai besar tetap persis.
 *
 * Keluaran **tanpa simbol mata uang**: DESIGN §6 menaruh simbol di judul kolom, bukan di setiap
 * sel. Pemisah ribuan/desimal mengikuti locale lewat `Intl`, digit tetap didapat dari font mono +
 * `tabular-nums` di CSS.
 */

export type MoneyDecimals = 2 | 4;

export interface MoneyOptions {
  /** Locale BCP-47 untuk pemisah ribuan/desimal. */
  locale?: string;
  /** Desimal tampilan; `2` (default) adalah skala penyimpanan (D-136). */
  decimals?: MoneyDecimals;
}

function decimalSeparator(locale: string): string {
  const part = new Intl.NumberFormat(locale).formatToParts(0.5).find((p) => p.type === "decimal");
  return part?.value ?? ".";
}

function groupInteger(digits: string, locale: string): string {
  return new Intl.NumberFormat(locale, {
    useGrouping: true,
    maximumFractionDigits: 0,
  }).format(BigInt(digits));
}

export function formatMoney(decimal: string, options: MoneyOptions = {}): string {
  const locale = options.locale ?? "id-ID";
  const decimals = options.decimals ?? 2;

  const match = /^([+-]?)(\d+)(?:\.(\d+))?$/.exec(decimal.trim());
  if (!match) {
    throw new Error(`nilai uang bukan desimal: ${decimal}`);
  }
  const [, sign = "", intDigits = "0", fraction = ""] = match;

  const scale = 10n ** BigInt(decimals);
  const kept = fraction.slice(0, decimals).padEnd(decimals, "0");
  let scaled = BigInt(intDigits + kept);

  // Half-even: lebih dari setengah → naik; tepat setengah → ke digit genap terdekat.
  const dropped = fraction.slice(decimals);
  if (dropped.length > 0) {
    const first = dropped[0] ?? "0";
    const restNonZero = /[1-9]/.test(dropped.slice(1));
    if (first > "5" || (first === "5" && (restNonZero || scaled % 2n === 1n))) {
      scaled += 1n;
    }
  }

  const separator = decimalSeparator(locale);
  if (scaled === 0n) {
    return `${groupInteger("0", locale)}${separator}${"0".repeat(decimals)}`;
  }

  const intPart = scaled / scale;
  const fracPart = (scaled % scale).toString().padStart(decimals, "0");
  const negative = sign === "-";
  return `${negative ? "-" : ""}${groupInteger(intPart.toString(), locale)}${separator}${fracPart}`;
}

/**
 * Menjumlahkan dua string desimal tanpa float (untuk baris total laporan).
 * Kedua masukan dibulatkan half-even ke `decimals` lebih dulu, lalu dijumlahkan sebagai `BigInt`.
 * Keluaran berupa desimal polos (tanpa pemisah ribuan) supaya bisa diformat sekali di lapisan UI.
 */
export function addMoney(a: string, b: string, decimals: MoneyDecimals = 2): string {
  const sum = scaledValue(a, decimals) + scaledValue(b, decimals);
  const scale = 10n ** BigInt(decimals);
  const negative = sum < 0n;
  const abs = negative ? -sum : sum;
  const intPart = (abs / scale).toString();
  const fracPart = (abs % scale).toString().padStart(decimals, "0");
  return `${negative ? "-" : ""}${intPart}.${fracPart}`;
}

export type MoneyInputError = "empty" | "invalid_format" | "not_positive" | "too_precise";

export type MoneyInputResult =
  | { ok: true; value: string }
  | { ok: false; error: MoneyInputError };

/**
 * Membaca nominal yang diketik teller menjadi desimal polos 2 desimal (spec §13, D-136).
 *
 * Aturan, sengaja ketat supaya tidak ada tebakan: digit saja, satu pemisah desimal (`,` atau `.`),
 * maksimum 2 desimal, tanpa pemisah ribuan, tanpa tanda. Nilai `> 0`. Tidak menyentuh `Number`:
 * keluaran dibentuk dari string, jadi tidak ada pembulatan float dan digit besar tetap utuh.
 *
 * `,` diterima karena teller mengetik nominal tunai dengan koma desimal; `.` diterima supaya
 * nilai yang disalin dari dokumen lain tidak perlu diubah tangan.
 */
export function parseMoneyInput(raw: string): MoneyInputResult {
  const text = raw.trim();
  if (text === "") {
    return { ok: false, error: "empty" };
  }

  const match = /^(\d+)(?:[.,](\d+))?$/.exec(text);
  if (!match) {
    return { ok: false, error: "invalid_format" };
  }
  const [, intDigits = "0", fraction = ""] = match;
  if (fraction.length > 2) {
    return { ok: false, error: "too_precise" };
  }

  const intPart = intDigits.replace(/^0+(?=\d)/, "");
  const value = `${intPart}.${fraction.padEnd(2, "0")}`;
  if (intPart === "0" && /^0*$/.test(fraction)) {
    return { ok: false, error: "not_positive" };
  }
  return { ok: true, value };
}

function scaledValue(decimal: string, decimals: MoneyDecimals): bigint {
  const match = /^([+-]?)(\d+)(?:\.(\d+))?$/.exec(decimal.trim());
  if (!match) {
    throw new Error(`nilai uang bukan desimal: ${decimal}`);
  }
  const [, sign = "", intDigits = "0", fraction = ""] = match;
  const kept = fraction.slice(0, decimals).padEnd(decimals, "0");
  let scaled = BigInt(intDigits + kept);
  const dropped = fraction.slice(decimals);
  if (dropped.length > 0) {
    const first = dropped[0] ?? "0";
    const restNonZero = /[1-9]/.test(dropped.slice(1));
    if (first > "5" || (first === "5" && (restNonZero || scaled % 2n === 1n))) {
      scaled += 1n;
    }
  }
  return sign === "-" ? -scaled : scaled;
}
