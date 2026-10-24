import AxeBuilder from "@axe-core/playwright";
import { requireDatabase } from "./db.js";
import { expect, test, type Locator, type Page } from "@playwright/test";

/**
 * Buku besar (`/app/ledger`) — gate a11y + navigasi keyboard (T-079).
 *
 * Data tabel berasal dari seed dev `packs/base/seed/0003_dev_ledger.sql` (izin baca buku besar untuk
 * `dev.maker` + periode tahun berjalan + satu jurnal demo seimbang), jadi tidak ada fixture API
 * yang perlu dibuat di sini dan hasilnya deterministik. `./task e2e` menjalankan `dbtools seed
 * --dev` lebih dulu.
 *
 * Yang dibuktikan:
 *   1. axe hijau pada `/app/ledger` × 2 tema × 2 locale (matriks a11y rute kerja);
 *   2. tabel bisa dicapai dan dinavigasi keyboard-only: Tab masuk (satu tab-stop komposit), panah
 *      pindah sel, Home/End ke tepi baris, Ctrl+Home/Ctrl+End ke ujung tabel, instruksi tersembunyi
 *      terbaca, Enter/Space tidak memicu aksi apa pun, dan Tab berikutnya keluar (tanpa keyboard
 *      trap).
 *
 * Batas: tanpa `KRAN_DATABASE_URL` (tidak ada API + DB dev) seluruh berkas dilewati.
 */

requireDatabase();

const MAKER = { username: "dev.maker", password: "rahasia-panjang-123" };
const LOCALES = ["id", "en"] as const;
const THEMES = ["light", "dark"] as const;

type Locale = (typeof LOCALES)[number];
type Theme = (typeof THEMES)[number];

/** Teks katalog (dibaca dari `packages/i18n/messages`, bukan tebakan test). */
type Text = {
  loginTitle: string;
  username: string;
  ledgerTitle: string;
  tableHelp: string;
};

const T: Record<Locale, Text> = {
  id: {
    loginTitle: "Masuk",
    username: "Nama pengguna",
    ledgerTitle: "Saldo buku besar",
    tableHelp:
      "Tabel saldo: Tab masuk ke tabel, tombol panah berpindah sel, Home/End ke tepi baris, Ctrl+Home/Ctrl+End ke sel pertama/terakhir, Tab berikutnya keluar dari tabel.",
  },
  en: {
    loginTitle: "Sign in",
    username: "Username",
    ledgerTitle: "Ledger balances",
    tableHelp:
      "Balance table: Tab enters the table, arrow keys move between cells, Home/End jump to the row edges, Ctrl+Home/Ctrl+End jump to the first/last cell, and the next Tab leaves the table.",
  },
};

/** Locale + tema sebelum render (strategi Paraglide `localStorage`, sama dengan spec lain). */
async function prepare(page: Page, locale: Locale, theme: Theme): Promise<void> {
  await page.addInitScript(
    (init: { locale: string; theme: string }) => {
      localStorage.setItem("PARAGLIDE_LOCALE", init.locale);
      localStorage.setItem("kran-theme", init.theme);
    },
    { locale, theme },
  );
}

/** Masuk lewat keyboard-only (fokus, ketik, Tab, ketik, Enter) — pola yang sama dengan spec lain. */
async function login(page: Page, text: Text): Promise<void> {
  await page.goto("/login");
  await expect(page.getByRole("heading", { level: 1, name: text.loginTitle })).toBeVisible();
  await page.getByLabel(text.username, { exact: true }).focus();
  await page.keyboard.type(MAKER.username);
  await page.keyboard.press("Tab");
  await page.keyboard.type(MAKER.password);
  await page.keyboard.press("Enter");
  await expect(page).toHaveURL(/\/app\/ledger$/);
  await expect(page.getByRole("heading", { level: 1, name: text.ledgerTitle })).toBeVisible();
}

/** Tabel saldo yang sudah terisi (seed dev menyediakan satu jurnal) — target gate axe & keyboard. */
async function ledgerGrid(page: Page): Promise<Locator> {
  const grid = page.getByRole("grid");
  await expect(grid).toBeVisible();
  await expect(grid.locator("tbody tr").first()).toBeVisible();
  return grid;
}

async function expectNoSeriousViolations(page: Page): Promise<void> {
  const results = await new AxeBuilder({ page }).analyze();
  const serious = results.violations.filter(
    (violation) => violation.impact === "serious" || violation.impact === "critical",
  );
  expect(
    serious.map((violation) => ({
      id: violation.id,
      impact: violation.impact,
      nodes: violation.nodes.map((node) => node.target.join(" ")),
    })),
  ).toEqual([]);
}

for (const locale of LOCALES) {
  for (const theme of THEMES) {
    test(`axe /app/ledger — locale ${locale}, tema ${theme}`, async ({ page }) => {
      await prepare(page, locale, theme);
      await login(page, T[locale]);
      await expect(page.locator("html")).toHaveAttribute("data-theme", theme);
      await ledgerGrid(page);
      await expectNoSeriousViolations(page);
    });
  }
}

test("keyboard /app/ledger: Tab masuk, panah/Home/End berpindah sel, Tab keluar", async ({
  page,
}) => {
  await prepare(page, "id", "light");
  await login(page, T.id);

  const grid = await ledgerGrid(page);

  // Instruksi tombol tersedia untuk pembaca layar lewat `aria-describedby`.
  await expect(grid).toHaveAttribute("aria-describedby", "ledger-table-help");
  await expect(page.locator("#ledger-table-help")).toHaveText(T.id.tableHelp);

  // Tab dari kontrol tepat sebelum tabel (filter kategori terakhir) → tabel. Ini membuktikan
  // tabel dapat dicapai keyboard dan merupakan satu tab-stop komposit (D-116 diamandemen).
  await page.locator(".kran-filter-bar .kran-filter-button").last().focus();
  await page.keyboard.press("Tab");
  await expect(grid).toBeFocused();
  await expect(grid).toHaveAttribute("aria-activedescendant", "ledger-cell-0-0");
  await expect(page.locator("#ledger-cell-0-0")).toHaveClass(/ledger-cell--active/);

  // Panah pindah sel; Home/End ke tepi baris; Ctrl+Home/Ctrl+End ke ujung tabel.
  await page.keyboard.press("ArrowRight");
  await expect(grid).toHaveAttribute("aria-activedescendant", "ledger-cell-0-1");
  await page.keyboard.press("End");
  await expect(grid).toHaveAttribute("aria-activedescendant", "ledger-cell-0-7");
  await page.keyboard.press("Home");
  await expect(grid).toHaveAttribute("aria-activedescendant", "ledger-cell-0-0");
  // Jurnal demo menyentuh dua akun (101 dan 201), jadi baris kedua pasti ada.
  await page.keyboard.press("ArrowDown");
  await expect(grid).toHaveAttribute("aria-activedescendant", "ledger-cell-1-0");
  await page.keyboard.press("Control+End");
  await expect(grid).toHaveAttribute("aria-activedescendant", /^ledger-cell-\d+-7$/);
  await page.keyboard.press("Control+Home");
  await expect(grid).toHaveAttribute("aria-activedescendant", "ledger-cell-0-0");

  // Sel aktif terlihat (focus visible): kelas aktif ada, dan cincin fokus dari token dipakai.
  const activeCell = page.locator("#ledger-cell-0-0");
  await expect(activeCell).toHaveClass(/ledger-cell--active/);

  // Enter/Space tidak memicu aksi destruktif apa pun (tabel hanya baca, tidak ada handler).
  await page.keyboard.press("Enter");
  await page.keyboard.press("Space");
  await expect(page).toHaveURL(/\/app\/ledger$/);
  await expect(grid).toBeFocused();

  // Tidak ada keyboard trap: Tab berikutnya meninggalkan tabel.
  await page.keyboard.press("Tab");
  await expect(grid).not.toBeFocused();
});
