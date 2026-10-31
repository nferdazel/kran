import AxeBuilder from "@axe-core/playwright";
import { expect, test, type APIRequestContext, type Page } from "@playwright/test";
import { requireDatabase } from "./db.js";

/**
 * Gate a11y + keyboard untuk monitor penutupan buku (T-139c): axe di 2 tema × 2 locale dan
 * jalur keyboard untuk kontrol yang selalu ada (muat ulang, batas riwayat).
 *
 * Aksi penutupan sengaja **tidak** dijalankan di sini: menutup buku mengubah tanggal bisnis dan
 * akan merusak spec lain yang berjalan sesudahnya. Yang diuji adalah halaman monitor dan
 * kontrolnya; aksi `run|resume|pause|cancel` sudah diuji di API (`itapi_dayclose`).
 */

requireDatabase();

const API = "http://127.0.0.1:8099";
const CONSOLE = { username: "dev.console", password: "rahasia-panjang-123" };
const LOCALES = ["id", "en"] as const;
const THEMES = ["light", "dark"] as const;

type Locale = (typeof LOCALES)[number];

const T: Record<
  Locale,
  { title: string; reload: string; limit: string; statusHeading: string; businessDate: string }
> = {
  id: {
    title: "Monitor penutupan buku",
    reload: "Muat ulang",
    limit: "Jumlah baris",
    statusHeading: "Status tanggal buku",
    businessDate: "Tanggal bisnis",
  },
  en: {
    title: "Day-close monitor",
    reload: "Reload",
    limit: "Rows",
    statusHeading: "Business date status",
    businessDate: "Business date",
  },
};

async function apiLogin(request: APIRequestContext): Promise<string> {
  const response = await request.post(`${API}/api/v1/auth/login`, { data: CONSOLE });
  expect(response.status(), "login dev.console").toBe(200);
  const cookie = response.headers()["set-cookie"] ?? "";
  const session = cookie.split(";")[0] ?? "";
  expect(session, "cookie sesi").toContain("kran_session=");
  return session;
}

async function browserLogin(page: Page, cookie: string): Promise<void> {
  const [name = "", value = ""] = cookie.split("=");
  await page.context().clearCookies();
  await page.context().addCookies([
    { name, value, domain: "127.0.0.1", path: "/", httpOnly: true, sameSite: "Lax" },
  ]);
}

async function prepare(page: Page, locale: Locale, theme: string): Promise<void> {
  await page.addInitScript(
    (init: { locale: string; theme: string }) => {
      localStorage.setItem("PARAGLIDE_LOCALE", init.locale);
      localStorage.setItem("kran-theme", init.theme);
    },
    { locale, theme },
  );
}

for (const locale of LOCALES) {
  for (const theme of THEMES) {
    test(`axe: /app/dayclose ${locale}/${theme}`, async ({ page, request }) => {
      const session = await apiLogin(request);
      await prepare(page, locale, theme);
      await browserLogin(page, session);

      await page.goto("/app/dayclose");
      await expect(page.getByRole("heading", { level: 1, name: T[locale].title })).toBeVisible();
      // Indikator shell memakai nilai dari API, bukan placeholder (spec §14.3). Locator dibatasi
      // ke header: teks "Business date" juga muncul di badan layar.
      const indicator = page.locator(".kran-business-date");
      await expect(indicator).toBeVisible();
      await expect(indicator).toContainText(T[locale].businessDate);
      await expect(
        page.getByRole("heading", { level: 2, name: T[locale].statusHeading }),
      ).toBeVisible();

      const results = await new AxeBuilder({ page }).analyze();
      const serious = results.violations.filter(
        (violation) => violation.impact === "serious" || violation.impact === "critical",
      );
      expect(
        serious,
        `/app/dayclose ${locale}/${theme}: ${serious.map((violation) => violation.id).join(", ")}`,
      ).toEqual([]);
    });
  }
}

test("keyboard: muat ulang dan batas riwayat bisa dipakai tanpa tetikus", async ({
  page,
  request,
}) => {
  const session = await apiLogin(request);
  await prepare(page, "id", "light");
  await browserLogin(page, session);

  await page.goto("/app/dayclose");
  await expect(page.getByRole("heading", { level: 1, name: T.id.title })).toBeVisible();

  // Kontrol sengaja disabled selama pemuatan: tunggu sampai bisa dipakai, jangan menguji balapan
  // dengan fetch pertama (yang gagal ter-fokus saat disabled bukan cacat keyboard).
  const reload = page.getByRole("button", { name: T.id.reload, exact: true });
  await expect(reload).toBeEnabled();
  await reload.focus();
  await expect(reload).toBeFocused();
  await reload.press("Enter");

  // Muat ulang tidak boleh menghasilkan galat pada data seed.
  await expect(
    page.getByRole("heading", { level: 2, name: T.id.statusHeading }),
  ).toBeVisible();
  await expect(page.getByRole("alert")).toHaveCount(0);

  // Kontrol riwayat harus tercapai dengan Tab dari tombol muat ulang: itu yang membuat halaman
  // bisa dipakai tanpa tetikus. Perilaku panah di dalam `<select>` native (membuka popup) tidak
  // diuji di sini — Chromium headless tidak merender popup itu, sehingga hasilnya mengukur
  // browser, bukan aplikasi. Reaksi aplikasi terhadap perubahan nilainya diuji terpisah di bawah.
  const limit = page.getByLabel(T.id.limit, { exact: true });
  await expect(limit).toBeEnabled();
  let reached = false;
  for (let i = 0; i < 15; i += 1) {
    await page.keyboard.press("Tab");
    if (await limit.evaluate((element) => element === document.activeElement)) {
      reached = true;
      break;
    }
  }
  expect(reached, "select batas riwayat tercapai dengan Tab").toBe(true);

  await limit.selectOption("50");
  await expect(limit).toHaveValue("50");
  await expect(page.getByRole("alert")).toHaveCount(0);
});
