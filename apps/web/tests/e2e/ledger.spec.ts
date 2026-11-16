import AxeBuilder from "@axe-core/playwright";

import { blockingViolations } from "./axe.js";
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
 *   2. satu tab-stop di `/app/ledger`: Tab dari filter kategori memfokuskan `.kran-table-wrap`
 *      (`role="region"`, `tabindex="0"`), tabelnya tabel native tanpa `tabindex`/`role`/
 *      `aria-activedescendant`, panah dan Home/End menggulir region yang sedang fokus, cincin fokus
 *      terlihat, dan Shift+Tab keluar tanpa keyboard trap (D-203).
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
      "Tabel saldo: Tab masuk ke area tabel, tombol panah dan Home/End menggulir area itu, Tab berikutnya keluar.",
  },
  en: {
    loginTitle: "Sign in",
    username: "Username",
    ledgerTitle: "Ledger balances",
    tableHelp:
      "Balance table: Tab enters the table area, arrow keys and Home/End scroll it, and the next Tab leaves it.",
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

/** Region tabel saldo yang sudah terisi (seed dev menyediakan satu jurnal) — target gate axe. */
async function ledgerRegion(page: Page): Promise<Locator> {
  const region = page.locator(".ledger-region");
  await expect(region).toBeVisible();
  await expect(region.locator("tbody tr").first()).toBeVisible();
  return region;
}

async function expectNoSeriousViolations(page: Page): Promise<void> {
  const results = await new AxeBuilder({ page }).analyze();
  const blocking = blockingViolations(results.violations);
  expect(
    blocking.map((violation) => ({
      id: violation.id,
      impact: violation.impact,
      nodes: violation.nodes.map((node) => node.target.join(" ")),
    })),
  ).toEqual([]);
}

for (const locale of LOCALES) {
  for (const theme of THEMES) {
    test(`axe /app/ledger — locale ${locale}, tema ${theme}`, async ({ page }) => {
      // Pemindaian axe atas tabel saldo adalah pekerjaan CPU, bukan interaksi: 30 dtk bawaan
      // memotongnya saat suite berjalan sesudah fase berat (O-107). Batas ini hanya untuk test
      // pemindaian, bukan untuk test alur.
      test.setTimeout(60_000);
      await prepare(page, locale, theme);
      await login(page, T[locale]);
      await expect(page.locator("html")).toHaveAttribute("data-theme", theme);
      await ledgerRegion(page);
      await expectNoSeriousViolations(page);
    });
  }
}

test("keyboard /app/ledger: satu tab stop di region tabel, panah menggulir, Shift+Tab keluar", async ({
  page,
}) => {
  await prepare(page, "id", "light");
  await login(page, T.id);

  const region = await ledgerRegion(page);
  const table = page.locator(".ledger-table");

  // Region pembungkus adalah satu-satunya tab stop tabel; tabelnya native (D-203).
  await expect(region).toHaveAttribute("role", "region");
  await expect(region).toHaveAttribute("tabindex", "0");
  await expect(region).toHaveAttribute("aria-describedby", "ledger-table-help");
  await expect(page.locator("#ledger-table-help")).toHaveText(T.id.tableHelp);
  expect(await page.getByRole("grid").count()).toBe(0);
  expect(
    await table.evaluate((el) => ({
      tabindex: el.getAttribute("tabindex"),
      role: el.getAttribute("role"),
      activeDescendant: el.getAttribute("aria-activedescendant"),
    })),
  ).toEqual({ tabindex: null, role: null, activeDescendant: null });

  // Tab dari kontrol tepat sebelum tabel (filter kategori terakhir) → region.
  await page.locator(".kran-filter-bar .kran-filter-button").last().focus();
  await page.keyboard.press("Tab");
  await expect(region).toBeFocused();

  // Cincin fokus dari token terlihat pada region yang fokus.
  const ring = await region.evaluate((el) => {
    const style = getComputedStyle(el);
    return { style: style.outlineStyle, width: parseFloat(style.outlineWidth) || 0 };
  });
  expect(ring.style, "region fokus harus punya cincin fokus").not.toBe("none");
  expect(ring.width).toBeGreaterThanOrEqual(2);

  // Panah dan End menggulir region yang sedang fokus, bukan halaman. Pada viewport lebar isi tabel
  // bisa muat; sumbu yang tidak meluap tidak bisa digulir, jadi yang diuji di situ adalah fokus
  // tetap di region dan halaman tidak ikut bergerak.
  const metrics = () =>
    region.evaluate((el) => ({
      scrollTop: el.scrollTop,
      scrollLeft: el.scrollLeft,
      scrollHeight: el.scrollHeight,
      clientHeight: el.clientHeight,
      scrollWidth: el.scrollWidth,
      clientWidth: el.clientWidth,
    }));
  const pageScroll = () =>
    page.evaluate(() => ({ x: window.scrollX, y: window.scrollY }));

  const before = await metrics();
  const pageBefore = await pageScroll();
  await page.keyboard.press("ArrowDown");
  await page.keyboard.press("End");
  await expect(region).toBeFocused();
  const afterVertical = await metrics();
  if (before.scrollHeight > before.clientHeight) {
    expect(afterVertical.scrollTop).toBeGreaterThan(before.scrollTop);
  }
  await page.keyboard.press("ArrowRight");
  await expect(region).toBeFocused();
  const afterHorizontal = await metrics();
  if (before.scrollWidth > before.clientWidth) {
    expect(afterHorizontal.scrollLeft).toBeGreaterThan(before.scrollLeft);
  }
  expect(await pageScroll()).toEqual(pageBefore);

  // Shift+Tab keluar dari region kembali ke kontrol filter; Tab masuk lagi (tanpa keyboard trap).
  await page.keyboard.press("Shift+Tab");
  await expect(region).not.toBeFocused();
  await expect(page.locator(".kran-filter-bar .kran-filter-button").last()).toBeFocused();
  await page.keyboard.press("Tab");
  await expect(region).toBeFocused();
});
