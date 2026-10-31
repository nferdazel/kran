import { requireDatabase } from "./db.js";
import { expect, test, type Page } from "@playwright/test";

/**
 * Visual regression gate (spec §15.8, O-022/D-176).
 *
 * **Baseline hanya untuk Linux.** Rendering font, antialiasing, dan scrollbar berbeda antar-OS,
 * jadi snapshot dari macOS tidak akan pernah cocok di runner. Test ini karena itu melewati diri
 * sendiri di luar Linux — gate-nya di `web-e2e` (ubuntu-24.04), bukan di mesin developer.
 *
 * Baseline dihasilkan di runner yang sama (`workflow_dispatch` + `--update-snapshots`), lalu
 * di-commit ke `visual.spec.ts-snapshots/`. Jangan membuat baseline di mesin lain: hasilnya hanya
 * akan menghasilkan diff yang tidak bisa ditindaklanjuti.
 *
 * Yang diambil hanya layar yang deterministik dari seed dev: halaman masuk dan buku besar. Nilai
 * yang berubah sendiri (tanggal buku, baris tabel yang bertambah oleh spec lain) di-mask; menambah
 * layar baru berarti menambah baseline Linux baru lewat alur yang sama.
 */

const MAKER = { username: "dev.maker", password: "rahasia-panjang-123" };
const THEMES = ["light", "dark"] as const;

type Theme = (typeof THEMES)[number];

/** Teks katalog `id` (login dipaksa berbahasa Indonesia seperti spec lain). */
const TEXT = {
  loginTitle: "Masuk",
  username: "Nama pengguna",
  ledgerTitle: "Saldo buku besar",
} as const;

async function prepare(page: Page, theme: Theme): Promise<void> {
  await page.addInitScript(
    (init: { locale: string; theme: string }) => {
      localStorage.setItem("PARAGLIDE_LOCALE", init.locale);
      localStorage.setItem("kran-theme", init.theme);
    },
    { locale: "id", theme },
  );
}

async function login(page: Page): Promise<void> {
  await page.goto("/login");
  await expect(page.getByRole("heading", { level: 1, name: TEXT.loginTitle })).toBeVisible();
  await page.getByLabel(TEXT.username, { exact: true }).focus();
  await page.keyboard.type(MAKER.username);
  await page.keyboard.press("Tab");
  await page.keyboard.type(MAKER.password);
  await page.keyboard.press("Enter");
  await expect(page).toHaveURL(/\/app\/ledger$/);
  await expect(page.getByRole("heading", { level: 1, name: TEXT.ledgerTitle })).toBeVisible();
}

/**
 * Bagian layar yang memang berubah sendiri: tanggal buku mengikuti jam sistem, dan isi tabel buku
 * besar bertambah setiap spec e2e lain menulis jurnal. Keduanya di-mask; yang dibandingkan adalah
 * kerangka halaman (shell, header, tipografi, token warna) yang justru paling sering berubah karena
 * CSS. Baseline tanpa mask hanya akan hijau bila run e2e kebetulan hanya menjalankan berkas ini.
 */
function dynamicMasks(page: Page) {
  return [page.locator(".kran-business-date"), page.locator(".kran-table")];
}

test.describe("visual regression (baseline Linux)", () => {
  test.skip(process.platform !== "linux", "baseline visual hanya dihasilkan di Linux (O-022)");
  requireDatabase();

  for (const theme of THEMES) {
    test(`halaman masuk — tema ${theme}`, async ({ page }) => {
      await prepare(page, theme);
      await page.goto("/login");
      await expect(page.getByRole("heading", { level: 1, name: TEXT.loginTitle })).toBeVisible();
      await expect(page.locator("html")).toHaveAttribute("data-theme", theme);

      await expect(page).toHaveScreenshot(`login-${theme}.png`, {
        animations: "disabled",
        caret: "hide",
        maxDiffPixelRatio: 0.01,
        mask: dynamicMasks(page),
      });
    });

    test(`buku besar — tema ${theme}`, async ({ page }) => {
      await prepare(page, theme);
      await login(page);
      await expect(page.getByRole("grid").locator("tbody tr").first()).toBeVisible();

      await expect(page).toHaveScreenshot(`ledger-${theme}.png`, {
        animations: "disabled",
        caret: "hide",
        maxDiffPixelRatio: 0.01,
        mask: dynamicMasks(page),
      });
    });
  }
});
