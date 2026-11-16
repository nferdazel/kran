import AxeBuilder from "@axe-core/playwright";

import { blockingViolations } from "./axe.js";
import { requireDatabase } from "./db.js";
import { expect, test, type APIRequestContext, type Page } from "@playwright/test";

/**
 * Parameter & jejak audit (T-241): hierarki layar, form ubah di dalam baris, dan pengumuman
 * realtime yang tidak ikut membacakan jam.
 *
 * Yang diuji adalah perilaku yang diminta arah desain T-241, bukan tata letak piksel: tidak ada
 * form bebas di atas tabel, form ubah terbuka dari barisnya dan ditutup `Esc` dengan fokus kembali
 * ke tombol baris itu, pencarian tanpa hasil menawarkan jalan pulih, dan live region hanya berisi
 * badge status.
 */

requireDatabase();

const API = "http://127.0.0.1:8099";
const MAKER = { username: "dev.maker", password: "rahasia-panjang-123" };
const LOCALES = ["id", "en"] as const;
const THEMES = ["light", "dark"] as const;

type Text = {
  title: string;
  activeHeading: string;
  edit: string;
  value: string;
  reason: string;
  submit: string;
  cancel: string;
  search: string;
  searchEmpty: (query: string) => string;
  clearSearch: string;
  connected: string;
};

const T: Record<"id" | "en", Text> = {
  id: {
    title: "Parameter & jejak audit",
    activeHeading: "Nilai parameter aktif",
    edit: "Ubah",
    value: "Nilai baru",
    reason: "Alasan",
    submit: "Ajukan perubahan",
    cancel: "Batal",
    search: "Cari parameter aktif",
    searchEmpty: (query) => `Tidak ada parameter yang cocok dengan "${query}".`,
    clearSearch: "Hapus pencarian",
    connected: "Terhubung",
  },
  en: {
    title: "Parameters & audit trail",
    activeHeading: "Active parameter values",
    edit: "Edit",
    value: "New value",
    reason: "Reason",
    submit: "Submit change",
    cancel: "Cancel",
    search: "Search active parameters",
    searchEmpty: (query) => `No parameter matches "${query}".`,
    clearSearch: "Clear search",
    connected: "Connected",
  },
};

async function apiLogin(
  request: APIRequestContext,
  user: { username: string; password: string },
): Promise<string> {
  const response = await request.post(`${API}/api/v1/auth/login`, {
    data: { username: user.username, password: user.password },
  });
  expect(response.status(), `login ${user.username}`).toBe(200);
  const cookie = response.headers()["set-cookie"] ?? "";
  return cookie.split(";")[0] ?? "";
}

async function browserLogin(page: Page, cookie: string): Promise<void> {
  const [name = "", value = ""] = cookie.split("=");
  await page.context().clearCookies();
  await page.context().addCookies([
    { name, value, domain: "127.0.0.1", path: "/", httpOnly: true, sameSite: "Lax" },
  ]);
}

async function prepare(page: Page, locale: string, theme: string): Promise<void> {
  await page.addInitScript(
    (init: { locale: string; theme: string }) => {
      localStorage.setItem("PARAGLIDE_LOCALE", init.locale);
      localStorage.setItem("kran-theme", init.theme);
    },
    { locale, theme },
  );
}

async function openParams(page: Page, text: Text): Promise<void> {
  await page.goto("/app/params");
  await expect(page.getByRole("heading", { level: 1, name: text.title })).toBeVisible();
  await expect(page.getByRole("heading", { level: 2, name: text.activeHeading })).toBeVisible();
  await expect(page.getByRole("table").first().locator("tbody tr").first()).toBeVisible();
}

test.describe.serial("parameter: hierarki dan form di dalam baris", () => {
  test("form ubah terbuka dari baris, Esc menutup, fokus kembali ke tombolnya", async ({
    page,
    request,
  }) => {
    const cookie = await apiLogin(request, MAKER);
    await prepare(page, "id", "light");
    await browserLogin(page, cookie);
    await openParams(page, T.id);

    // Tidak ada form bebas di atas tabel: tombol ajukan baru ada setelah baris dibuka.
    await expect(page.getByRole("button", { name: T.id.submit, exact: true })).toHaveCount(0);

    const row = page.getByRole("table").first().locator("tbody tr").first();
    const edit = row.getByRole("button", { name: T.id.edit, exact: true });
    await edit.press("Enter");

    const valueField = page.getByRole("textbox", { name: T.id.value, exact: true });
    await expect(valueField).toBeFocused();
    await expect(page.getByRole("button", { name: T.id.submit, exact: true })).toHaveCount(1);

    await page.keyboard.press("Escape");
    await expect(valueField).toHaveCount(0);
    await expect(edit).toBeFocused();
  });

  test("pencarian tanpa hasil: keadaan kosong menyebut kueri dan bisa dihapus", async ({
    page,
    request,
  }) => {
    const cookie = await apiLogin(request, MAKER);
    await prepare(page, "id", "light");
    await browserLogin(page, cookie);
    await openParams(page, T.id);

    const query = "zzz-tidak-ada-param";
    await page.getByLabel(T.id.search, { exact: true }).fill(query);
    await expect(page.getByText(T.id.searchEmpty(query), { exact: true })).toBeVisible();

    await page.getByRole("button", { name: T.id.clearSearch, exact: true }).press("Enter");
    await expect(page.getByRole("table").first().locator("tbody tr").first()).toBeVisible();
    await expect(page.getByLabel(T.id.search, { exact: true })).toHaveValue("");
  });

  test("live region hanya berisi badge status, jam terakhir diperbarui di luar", async ({
    page,
    request,
  }) => {
    const cookie = await apiLogin(request, MAKER);
    await prepare(page, "id", "light");
    await browserLogin(page, cookie);
    await openParams(page, T.id);

    const live = page.locator('[role="status"]').first();
    await expect(live).toContainText(T.id.connected);
    // Jam tidak boleh berada di dalam live region: refresh berulang tidak perlu membacakannya.
    await expect(live).not.toContainText("pukul");
  });

  test("axe: parameter dengan data × 2 tema × 2 locale", async ({ page, request }) => {
    test.setTimeout(180_000);
    const cookie = await apiLogin(request, MAKER);
    await browserLogin(page, cookie);

    for (const locale of LOCALES) {
      for (const theme of THEMES) {
        const text = T[locale];
        await prepare(page, locale, theme);
        await openParams(page, text);
        const results = await new AxeBuilder({ page }).analyze();
        const blocking = blockingViolations(results.violations);
        expect(blocking, `${locale}/${theme} params: ${blocking.map((v) => v.id).join(", ")}`).toEqual(
          [],
        );
      }
    }
  });
});
