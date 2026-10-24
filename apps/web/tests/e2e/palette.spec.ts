import AxeBuilder from "@axe-core/playwright";
import { requireDatabase } from "./db.js";
import { expect, test, type Page } from "@playwright/test";

/**
 * Command palette (T-110, spec §14.3 "keyboard-first"): `Ctrl+K` membuka, pencarian menyaring,
 * panah + Enter membuka tujuan, `Esc` menutup dan mengembalikan fokus, state kosong jujur, plus
 * gate axe **dengan dialog terbuka** × 2 tema × 2 locale.
 *
 * Batas yang diuji: aksi palette = **navigasi** ke halaman yang sudah ada (tanpa aksi mutasi), dan
 * `Ctrl+K` tidak direbut saat fokus ada di field teks (keputusan di `docs/tasks/T-110.md`).
 *
 * Butuh DB + seed user dev (`./task e2e` menyiapkannya). Tanpa `KRAN_DATABASE_URL` **seluruh**
 * berkas dilewati karena semua skenario butuh login.
 */

requireDatabase();

const MAKER = { username: "dev.maker", password: "rahasia-panjang-123" };
const LOCALES = ["id", "en"] as const;
const THEMES = ["light", "dark"] as const;

/** Teks katalog (dibaca dari `packages/i18n/messages`, bukan tebakan test). */
type Text = {
  loginTitle: string;
  paletteHeading: string;
  searchLabel: string;
  hint: string;
  empty: string;
  ledger: string;
  teller: string;
  accounts: string;
  params: string;
  products: string;
  paramsTitle: string;
  newValue: string;
};

const T: Record<"id" | "en", Text> = {
  id: {
    loginTitle: "Masuk",
    paletteHeading: "Palet perintah",
    searchLabel: "Cari perintah",
    hint: "Panah atas dan bawah memilih, Enter membuka, Esc menutup.",
    empty: "Tidak ada perintah yang cocok.",
    ledger: "Buku besar",
    teller: "Teller",
    accounts: "Buka rekening",
    params: "Parameter",
    products: "Produk",
    paramsTitle: "Parameter & jejak audit",
    newValue: "Nilai baru",
  },
  en: {
    loginTitle: "Sign in",
    paletteHeading: "Command palette",
    searchLabel: "Search commands",
    hint: "Arrow keys choose, Enter opens, Esc closes.",
    empty: "No matching command.",
    ledger: "Ledger",
    teller: "Teller",
    accounts: "Open account",
    params: "Parameters",
    products: "Products",
    paramsTitle: "Parameters & audit trail",
    newValue: "New value",
  },
};

/** Locale + tema sebelum render (strategi Paraglide `localStorage`, sama dengan spec lain). */
async function prepare(page: Page, locale: string, theme: string): Promise<void> {
  await page.addInitScript(
    (init: { locale: string; theme: string }) => {
      localStorage.setItem("PARAGLIDE_LOCALE", init.locale);
      localStorage.setItem("kran-theme", init.theme);
    },
    { locale, theme },
  );
}

async function login(page: Page, text: Text): Promise<void> {
  await page.goto("/login");
  await expect(page.getByRole("heading", { level: 1, name: text.loginTitle })).toBeVisible();
  await page.getByLabel(text === T.id ? "Nama pengguna" : "Username", { exact: true }).focus();
  await page.keyboard.type(MAKER.username);
  await page.keyboard.press("Tab");
  await page.keyboard.type(MAKER.password);
  await page.keyboard.press("Enter");
  await expect(page).toHaveURL(/\/app\/ledger$/);
}

/** Palette dibuka dari mana saja di `/app/*`; menunggu fokus di field pencarian = siap dipakai. */
async function openPalette(page: Page, text: Text) {
  await page.keyboard.press("Control+k");
  const dialog = page.getByRole("dialog", { name: text.paletteHeading });
  await expect(dialog).toBeVisible();
  await expect(dialog.getByLabel(text.searchLabel, { exact: true })).toBeFocused();
  return dialog;
}

/** Tautan menu di header (di luar dialog) — dipakai sebagai "elemen pemicu" fokus. */
function navLink(page: Page, name: string) {
  return page.getByRole("navigation").getByRole("link", { name, exact: true });
}

test.describe.serial("command palette", () => {
  test("Ctrl+K membuka, pencarian menyaring, panah + Enter membuka tujuan", async ({ page }) => {
    await prepare(page, "id", "light");
    await login(page, T.id);

    const dialog = await openPalette(page, T.id);
    await expect(dialog.getByText(T.id.hint)).toBeVisible();

    // Substring tanpa peduli huruf besar/kecil, lewat label bahasa aktif maupun bahasa lain.
    await page.keyboard.type("tell");
    await expect(dialog.getByRole("link", { name: T.id.teller, exact: true })).toBeVisible();
    await expect(dialog.getByRole("link", { name: T.id.products, exact: true })).toHaveCount(0);
    // "products" (en) menemukan "Produk" (id): kata kunci mencakup seluruh locale.
    await dialog.getByLabel(T.id.searchLabel, { exact: true }).fill("products");
    await expect(dialog.getByRole("link", { name: T.id.products, exact: true })).toBeVisible();

    // Panah memindahkan fokus ke aksi; Enter membuka tautan (navigasi native).
    await page.keyboard.press("ArrowDown");
    await expect(dialog.getByRole("link", { name: T.id.products, exact: true })).toBeFocused();
    await page.keyboard.press("Enter");
    await expect(page).toHaveURL(/\/app\/products$/);
    await expect(dialog).toBeHidden();
  });

  test("Enter dari pencarian membuka hasil teratas", async ({ page }) => {
    await prepare(page, "id", "light");
    await login(page, T.id);

    const dialog = await openPalette(page, T.id);
    await dialog.getByLabel(T.id.searchLabel, { exact: true }).fill("teller");
    await page.keyboard.press("Enter");

    await expect(page).toHaveURL(/\/app\/teller$/);
    // Palette ditutup di akhir supaya tidak menutupi interaksi spec lain (worker berbagi satu halaman).
    await expect(dialog).toBeHidden();
  });

  test("klik aksi menavigasi dan menutup palette", async ({ page }) => {
    await prepare(page, "id", "light");
    await login(page, T.id);

    const dialog = await openPalette(page, T.id);
    await dialog.getByRole("link", { name: T.id.params, exact: true }).click();

    await expect(page).toHaveURL(/\/app$/);
    await expect(dialog).toBeHidden();
  });

  test("tanpa kecocokan: state kosong, bukan daftar kosong tanpa penjelasan", async ({ page }) => {
    await prepare(page, "id", "light");
    await login(page, T.id);

    const dialog = await openPalette(page, T.id);
    await dialog.getByLabel(T.id.searchLabel, { exact: true }).fill("pinjaman mikro");

    await expect(dialog.getByText(T.id.empty)).toBeVisible();
    await expect(dialog.getByRole("link")).toHaveCount(0);

    // Kueri kosong mengembalikan seluruh daftar untuk operator maker: buku besar, teller, buka
    // rekening, parameter, produk. Seed dev `0003_dev_ledger.sql` memberi `dev.maker` izin baca
    // buku besar supaya tabel ledger punya fixture untuk gate axe/keyboard T-079; `param_maker`
    // juga memegang `deposit.account.manage`, jadi layar buka rekening ikut tampil.
    await dialog.getByLabel(T.id.searchLabel, { exact: true }).fill("");
    await expect(dialog.getByRole("link")).toHaveCount(5);
    await expect(dialog.getByRole("link", { name: T.id.ledger, exact: true })).toBeVisible();
    await expect(dialog.getByRole("link", { name: T.id.accounts, exact: true })).toBeVisible();

    await page.keyboard.press("Escape");
    await expect(dialog).toBeHidden();
  });

  test("Esc menutup dan mengembalikan fokus ke elemen pemicu", async ({ page }) => {
    await prepare(page, "id", "light");
    await login(page, T.id);

    const trigger = navLink(page, T.id.teller);
    await trigger.focus();
    await expect(trigger).toBeFocused();

    const dialog = await openPalette(page, T.id);
    await page.keyboard.press("Escape");
    await expect(dialog).toBeHidden();
    await expect(trigger).toBeFocused();
  });

  test("Tab membungkus di dalam dialog (focus trap), bukan keluar ke halaman", async ({
    page,
  }) => {
    await prepare(page, "id", "light");
    await login(page, T.id);

    const dialog = await openPalette(page, T.id);
    const search = dialog.getByLabel(T.id.searchLabel, { exact: true });
    const options = dialog.getByRole("link");
    const count = await options.count();

    for (let i = 0; i < count; i += 1) {
      await page.keyboard.press("Tab");
      await expect(options.nth(i)).toBeFocused();
    }
    // Satu Tab lagi dari aksi terakhir kembali ke field pencarian (bukan ke header/footer).
    await page.keyboard.press("Tab");
    await expect(search).toBeFocused();
    await page.keyboard.press("Shift+Tab");
    await expect(options.nth(count - 1)).toBeFocused();

    await page.keyboard.press("Escape");
    await expect(dialog).toBeHidden();
  });

  test("Ctrl+K tidak direbut saat fokus ada di field teks", async ({ page }) => {
    await prepare(page, "id", "light");
    await login(page, T.id);

    // Halaman Parameter punya field teks nyata; di sana Ctrl+K milik field (bukan palette).
    await page.goto("/app");
    await expect(page.getByRole("heading", { level: 1, name: T.id.paramsTitle })).toBeVisible();
    await page.getByLabel(T.id.newValue, { exact: true }).focus();
    await page.keyboard.press("Control+k");

    await expect(page.getByRole("dialog", { name: T.id.paletteHeading })).toBeHidden();
  });

  test("axe: dialog terbuka × 2 tema × 2 locale", async ({ page }) => {
    test.setTimeout(180_000);
    await prepare(page, "id", "light");
    await login(page, T.id);

    for (const locale of LOCALES) {
      for (const theme of THEMES) {
        const text = T[locale];
        await prepare(page, locale, theme);
        await page.reload();
        await expect(page.getByRole("heading", { level: 1 })).toBeVisible();

        const dialog = await openPalette(page, text);
        await expect(dialog.getByRole("link", { name: text.teller, exact: true })).toBeVisible();

        const results = await new AxeBuilder({ page }).analyze();
        const serious = results.violations.filter(
          (violation) => violation.impact === "serious" || violation.impact === "critical",
        );
        expect(
          serious,
          `${locale}/${theme} palette: ${serious.map((violation) => violation.id).join(", ")}`,
        ).toEqual([]);

        // Tutup tiap putaran: putaran berikutnya mereload halaman, tetapi palette yang tertinggal
        // akan menutupi interaksi spec lain pada worker yang sama.
        await page.keyboard.press("Escape");
        await expect(dialog).toBeHidden();
      }
    }
  });
});
