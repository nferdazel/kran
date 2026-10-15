import AxeBuilder from "@axe-core/playwright";
import { expect, test, type Page } from "@playwright/test";

/**
 * Gate a11y (spec §17.2): axe-core pada rute utama × 2 tema × 2 locale, gagal untuk pelanggaran
 * ber-dampak serious/critical.
 *
 * Locale diset eksplisit lewat `localStorage` (strategi Paraglide memakainya) supaya hasil test
 * tidak bergantung pada bahasa browser: tanpa itu locale jatuh ke `preferredLanguage` (en-US di
 * Chromium) dan test akan rapuh.
 */

const LOCALES = ["id", "en"] as const;
const THEMES = ["light", "dark"] as const;

type Locale = (typeof LOCALES)[number];
type Theme = (typeof THEMES)[number];

/** Teks yang diharapkan per locale (dibaca dari katalog, bukan tebakan test). */
const TEXT: Record<
  Locale,
  { h1: string; appTitle: string; themeDark: string; themeLight: string; localeLabel: string }
> = {
  id: {
    h1: "Selamat datang",
    appTitle: "KRAN — Sistem Koperasi & Bank",
    themeDark: "Gelap",
    themeLight: "Terang",
    localeLabel: "Bahasa",
  },
  en: {
    h1: "Welcome",
    appTitle: "KRAN — Cooperative & Bank System",
    themeDark: "Dark",
    themeLight: "Light",
    localeLabel: "Language",
  },
};

/**
 * Pola untuk `toHaveTitle`: Playwright mencocokkan judul **utuh** dengan string, sedangkan judul
 * halaman berisi nama aplikasi + nama rute. Teksnya dari katalog, jadi metacharacter regex di-escape.
 */
function titlePattern(text: string): RegExp {
  return new RegExp(text.replace(/[.*+?^${}()|[\]\\]/g, "\\$&"));
}

async function gotoApp(page: Page, locale: Locale, theme: Theme = "light"): Promise<void> {
  await page.addInitScript(
    (init: { locale: string; theme: string }) => {
      localStorage.setItem("PARAGLIDE_LOCALE", init.locale);
      localStorage.setItem("kran-theme", init.theme);
    },
    { locale, theme },
  );
  await page.goto("/");
  // Tunggu aplikasi benar-benar ter-render (SPA): tanpa ini, interaksi pertama bisa terjadi
  // sebelum hydration selesai.
  await expect(page.getByRole("heading", { level: 1 })).toHaveText(TEXT[locale].h1);
}

for (const locale of LOCALES) {
  for (const theme of THEMES) {
    test(`axe: locale ${locale}, tema ${theme}`, async ({ page }) => {
      await gotoApp(page, locale, theme);

      await expect(page.locator("html")).toHaveAttribute("data-theme", theme);
      await expect(page.locator("html")).toHaveAttribute("lang", locale);

      const results = await new AxeBuilder({ page }).analyze();
      const serious = results.violations.filter(
        (v) => v.impact === "serious" || v.impact === "critical",
      );

      // Pesan eksplisit supaya kegagalan bisa ditindaklanjuti tanpa membuka trace.
      expect(
        serious.map((v) => ({
          id: v.id,
          impact: v.impact,
          description: v.description,
          nodes: v.nodes.map((n) => n.target.join(" ")),
        })),
      ).toEqual([]);
    });
  }
}

test("struktur shell: landmark, judul halaman, dan indikator business date", async ({ page }) => {
  await gotoApp(page, "id");

  await expect(page.locator("header")).toBeVisible();
  await expect(page.locator("nav[aria-label]")).toBeVisible();
  await expect(page.locator("main#main")).toBeVisible();
  await expect(page.locator("footer")).toBeVisible();

  // Judul halaman unik per rute (spec §17.1).
  await expect(page).toHaveTitle(titlePattern(TEXT.id.appTitle));

  // Indikator business date selalu tampak (spec §14.3).
  await expect(page.getByText("Tanggal bisnis")).toBeVisible();
});

test("ganti tema mengubah atribut dan mengumumkannya lewat live region", async ({ page }) => {
  await gotoApp(page, "id", "light");

  await page.getByLabel(TEXT.id.themeDark).check();
  await expect(page.locator("html")).toHaveAttribute("data-theme", "dark");
  await expect(page.getByRole("status")).toContainText(TEXT.id.themeDark);

  await page.getByLabel(TEXT.id.themeLight).check();
  await expect(page.locator("html")).toHaveAttribute("data-theme", "light");
  await expect(page.getByRole("status")).toContainText(TEXT.id.themeLight);
});

test("ganti bahasa mengganti isi dan mengumumkannya lewat live region", async ({ page }) => {
  await gotoApp(page, "id");

  await page.getByRole("radio", { name: "Inggris" }).check();

  await expect(page.locator("html")).toHaveAttribute("lang", "en");
  await expect(page.getByRole("heading", { level: 1 })).toHaveText(TEXT.en.h1);
  await expect(page.getByRole("status")).toContainText("English");
});

test("tidak ada string hardcode: judul & label ikut berganti bahasa", async ({ page }) => {
  await gotoApp(page, "id");
  await expect(page.getByRole("heading", { level: 2 }).first()).toHaveText("Status sistem");

  await page.getByRole("radio", { name: "Inggris" }).check();
  await expect(page.getByRole("heading", { level: 2 }).first()).toHaveText("System status");
});
