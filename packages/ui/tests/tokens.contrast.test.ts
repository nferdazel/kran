import { readFileSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { describe, expect, it } from "vitest";
import { contrastRatio, parseThemeColorTokens } from "../src/contrast.js";

/**
 * Test kontras token (spec §15.4): seluruh pasangan token diuji pada KEDUA tema.
 *  - teks normal >= 4.5:1
 *  - teks besar & komponen/UI >= 3:1
 * Test GAGAL bila ada token yang melanggar ambang, atau token hilang dari salah satu tema.
 */

const css = readFileSync(fileURLToPath(new URL("../tokens/tokens.css", import.meta.url)), "utf8");

const THEMES = ["light", "dark"] as const;

/** Pasangan yang dipakai sebagai teks normal (>= 4.5:1). */
const TEXT_PAIRS: ReadonlyArray<readonly [string, string]> = [
  ["text", "bg"],
  ["text", "surface"],
  ["text-muted", "bg"],
  ["text-muted", "surface"],
  ["primary", "bg"],
  ["primary", "surface"],
  ["danger", "bg"],
  ["danger", "surface"],
  ["success", "bg"],
  ["warning", "bg"],
  ["text-on-primary", "primary"],
];

/** Pasangan non-teks / teks besar (>= 3:1). */
const UI_PAIRS: ReadonlyArray<readonly [string, string]> = [
  ["border", "bg"],
  ["border", "surface"],
  ["focus-ring", "bg"],
  ["focus-ring", "surface"],
];

/** Token wajib ada di setiap tema (spec §15.1). */
const REQUIRED_TOKENS = [
  "bg",
  "surface",
  "surface-raised",
  "text",
  "text-muted",
  "text-on-primary",
  "border",
  "primary",
  "primary-hover",
  "danger",
  "success",
  "warning",
  "focus-ring",
];

const TEXT_MIN = 4.5;
const UI_MIN = 3;

describe.each(THEMES)("token kontras tema %s", (theme) => {
  const tokens = parseThemeColorTokens(css, theme);

  it("mendefinisikan seluruh token warna wajib", () => {
    for (const name of REQUIRED_TOKENS) {
      expect(tokens.has(name), `token --color-${name} hilang di tema ${theme}`).toBe(true);
      expect(tokens.get(name), `token --color-${name} kosong di tema ${theme}`).toBeTruthy();
    }
  });

  it.each(TEXT_PAIRS)("teks normal %s di atas %s >= %s", (fg, bg) => {
    const foreground = tokens.get(fg);
    const background = tokens.get(bg);
    expect(foreground, `token --color-${fg} tidak ada`).toBeTruthy();
    expect(background, `token --color-${bg} tidak ada`).toBeTruthy();
    const ratio = contrastRatio(foreground as string, background as string);
    expect(ratio, `kontras ${fg}/${bg} = ${ratio.toFixed(2)} (< ${TEXT_MIN})`).toBeGreaterThanOrEqual(
      TEXT_MIN,
    );
  });

  it.each(UI_PAIRS)("UI/teks besar %s di atas %s >= %s", (fg, bg) => {
    const foreground = tokens.get(fg);
    const background = tokens.get(bg);
    expect(foreground, `token --color-${fg} tidak ada`).toBeTruthy();
    expect(background, `token --color-${bg} tidak ada`).toBeTruthy();
    const ratio = contrastRatio(foreground as string, background as string);
    expect(ratio, `kontras ${fg}/${bg} = ${ratio.toFixed(2)} (< ${UI_MIN})`).toBeGreaterThanOrEqual(
      UI_MIN,
    );
  });
});

describe("diri sendiri (sanity check rasio)", () => {
  it("hitam/putih = 21:1", () => {
    expect(contrastRatio("#000000", "#ffffff")).toBeCloseTo(21, 5);
  });
  it("warna identik = 1:1", () => {
    expect(contrastRatio("#1d4ed8", "#1d4ed8")).toBeCloseTo(1, 5);
  });
});
