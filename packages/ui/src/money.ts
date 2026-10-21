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
  /** 4 untuk jurnal/laporan (default), 2 untuk layar tunai. */
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
  const decimals = options.decimals ?? 4;

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
