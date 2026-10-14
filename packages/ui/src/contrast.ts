/**
 * Utilitas kontras WCAG 2.2 (spec §15.4). Dipakai test token; sengaja tanpa dependensi
 * supaya rasio bisa dihitung ulang siapa pun.
 */

export type Rgb = readonly [number, number, number];

/** Terima `#rrggbb` (dengan `#` opsional). Lempar bila bentuknya tidak dikenal. */
export function parseHexColor(input: string): Rgb {
  const hex = input.trim().replace(/^#/, "");
  if (!/^[0-9a-fA-F]{6}$/.test(hex)) {
    throw new Error(`bukan warna heks 6 digit: ${input}`);
  }
  return [
    Number.parseInt(hex.slice(0, 2), 16),
    Number.parseInt(hex.slice(2, 4), 16),
    Number.parseInt(hex.slice(4, 6), 16),
  ];
}

function channelLuminance(value: number): number {
  const c = value / 255;
  return c <= 0.03928 ? c / 12.92 : ((c + 0.055) / 1.055) ** 2.4;
}

/** Luminance relatif WCAG. */
export function relativeLuminance(color: string): number {
  const [r, g, b] = parseHexColor(color);
  return 0.2126 * channelLuminance(r) + 0.7152 * channelLuminance(g) + 0.0722 * channelLuminance(b);
}

/** Rasio kontras WCAG (>= 1). Urutan argumen tidak berpengaruh. */
export function contrastRatio(foreground: string, background: string): number {
  const a = relativeLuminance(foreground);
  const b = relativeLuminance(background);
  const lighter = Math.max(a, b);
  const darker = Math.min(a, b);
  return (lighter + 0.05) / (darker + 0.05);
}

/**
 * Ambil token warna satu tema dari teks CSS.
 * Hanya mencari blok `[data-theme="<theme>"] { ... }` tanpa kurung bersarang
 * (blok token memang hanya berisi deklarasi), lalu mengembalikan peta
 * nama-tanpa-prefix -> nilai, mis. `text -> #12181f` dari `--color-text: #12181f;`.
 */
export function parseThemeColorTokens(css: string, theme: string): Map<string, string> {
  const block = new RegExp(`\\[data-theme="${theme}"\\]\\s*\\{([^}]*)\\}`, "s").exec(css);
  if (!block || block[1] === undefined) {
    throw new Error(`blok token warna untuk tema "${theme}" tidak ditemukan`);
  }
  const tokens = new Map<string, string>();
  for (const line of block[1].split(";")) {
    const match = /--color-([a-z0-9-]+)\s*:\s*([^;]+)/.exec(line);
    if (match && match[1] !== undefined && match[2] !== undefined) {
      tokens.set(match[1], match[2].trim());
    }
  }
  return tokens;
}
