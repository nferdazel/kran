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
  ["text", "surface-raised"],
  ["text", "surface-disabled"],
  ["text", "selected"],
  ["text-muted", "bg"],
  ["text-muted", "surface"],
  ["text-muted", "surface-raised"],
  ["text-muted", "surface-disabled"],
  ["text-muted", "selected"],
  ["text-2", "bg"],
  ["text-2", "surface"],
  ["primary", "bg"],
  ["primary", "surface"],
  ["accent", "bg"],
  ["accent", "surface"],
  ["accent", "selected"],
  ["primary", "selected"],
  ["success", "bg"],
  ["success", "surface"],
  ["positive", "bg"],
  ["positive", "surface"],
  ["danger", "bg"],
  ["danger", "surface"],
  ["negative", "bg"],
  ["negative", "surface"],
  ["warning", "bg"],
  ["warning", "surface"],
  ["info", "bg"],
  ["info", "surface"],
  ["text-on-primary", "primary"],
  ["text-on-primary", "primary-hover"],
  // Status di atas tint-nya sendiri (DESIGN §3: tint status wajib masuk matriks).
  ["text", "success-tint"],
  ["text", "danger-tint"],
  ["text", "warning-tint"],
  ["text", "info-tint"],
  ["text-muted", "success-tint"],
  ["text-muted", "danger-tint"],
  ["text-muted", "warning-tint"],
  ["text-muted", "info-tint"],
  ["success", "success-tint"],
  ["danger", "danger-tint"],
  ["warning", "warning-tint"],
  ["info", "info-tint"],
];

/** Pasangan non-teks / teks besar (>= 3:1). */
const UI_PAIRS: ReadonlyArray<readonly [string, string]> = [
  ["border", "bg"],
  ["border", "surface"],
  ["border", "surface-raised"],
  ["border", "surface-disabled"],
  ["focus-ring", "bg"],
  ["focus-ring", "surface"],
  ["focus-ring", "surface-raised"],
  ["focus-ring", "selected"],
];

/** Token wajib ada di setiap tema (spec §15.1, DESIGN §3). */
const REQUIRED_TOKENS = [
  "bg",
  "surface",
  "surface-raised",
  "surface-disabled",
  "selected",
  "text",
  "text-muted",
  "text-2",
  "text-on-primary",
  "hairline",
  "border",
  "primary",
  "primary-hover",
  "accent",
  "success",
  "positive",
  "danger",
  "negative",
  "warning",
  "info",
  "focus-ring",
  "success-tint",
  "danger-tint",
  "warning-tint",
  "info-tint",
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
