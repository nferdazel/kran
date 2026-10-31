import { expect, test, type Page } from "@playwright/test";

/**
 * Skenario keyboard-only (spec §17.2): tidak ada klik di berkas ini — seluruh interaksi lewat
 * Tab/Enter/panah, termasuk skip link, grup radio tema, dan select bahasa.
 *
 * Urutan fokus yang diuji adalah urutan DOM yang sebenarnya:
 *   skip link → field formulir login → tombol kirim → pengaturan tampilan di footer. Halaman publik
 *   tidak menampilkan menu area kerja (nav hanya untuk `/app`), dan pengaturan tema/bahasa tidak
 *   lagi mendahului konten (DESIGN §10).
 */

async function gotoApp(page: Page, locale = "id", theme = "light"): Promise<void> {
  await page.addInitScript(
    (init: { locale: string; theme: string }) => {
      localStorage.setItem("PARAGLIDE_LOCALE", init.locale);
      localStorage.setItem("kran-theme", init.theme);
    },
    { locale, theme },
  );
  await page.goto("/");
  await expect(page.getByRole("heading", { level: 1 })).toBeVisible();
}

async function activeElement(page: Page): Promise<string> {
  return page.evaluate(() => {
    const el = document.activeElement as HTMLElement | null;
    if (!el) return "none";
    const name = el.getAttribute("name") ?? el.id ?? "";
    return `${el.tagName.toLowerCase()}:${el.getAttribute("type") ?? ""}:${name}`.trim();
  });
}

test("skip link memindahkan fokus ke konten utama", async ({ page }) => {
  await gotoApp(page);

  await page.keyboard.press("Tab");
  const skip = page.locator("a.kran-skip-link");
  await expect(skip).toBeFocused();
  await expect(skip).toBeVisible();

  await page.keyboard.press("Enter");
  await expect(page.locator("main#main")).toBeFocused();
});

test("tema bisa diganti hanya dengan keyboard (panah dalam grup radio)", async ({ page }) => {
  await gotoApp(page, "id", "light");

  // Radio tema = satu grup; Tab masuk ke radio yang terpilih ("Terang"), panah memindah pilihan.
  const light = page.getByRole("radio", { name: "Terang" });
  await light.focus();
  await expect(light).toBeFocused();
  await expect(light).toBeChecked();

  await page.keyboard.press("ArrowRight");

  const dark = page.getByRole("radio", { name: "Gelap" });
  await expect(dark).toBeChecked();
  await expect(page.locator("html")).toHaveAttribute("data-theme", "dark");
  await expect(page.getByRole("status")).toContainText("Gelap");
});

test("bahasa bisa diganti hanya dengan keyboard (panah dalam grup radio)", async ({ page }) => {
  await gotoApp(page);

  const indonesia = page.getByRole("radio", { name: "Indonesia" });
  await indonesia.focus();
  await expect(indonesia).toBeChecked();
  await page.keyboard.press("ArrowRight"); // pindah ke "Inggris" tanpa mouse

  await expect(page.locator("html")).toHaveAttribute("lang", "en");
  await expect(page.getByRole("heading", { level: 1 })).toHaveText("Sign in");
  await expect(page.getByRole("status")).toContainText("English");
});

test("setiap kontrol dapat dijangkau keyboard dalam urutan logis", async ({ page }) => {
  await gotoApp(page);

  await page.keyboard.press("Tab");
  await expect(page.locator("a.kran-skip-link")).toBeFocused();

  const urutan: string[] = [];
  for (let i = 0; i < 3; i += 1) {
    await page.keyboard.press("Tab");
    urutan.push(await activeElement(page));
  }

  // Pengaturan tampilan pindah ke footer (DESIGN §10): konten lebih dulu, pengaturan sesudahnya.
  // Urutan: field login, lalu submit; radio tema/bahasa tidak lagi mendahului isi halaman.
  expect(urutan).toEqual(["input:text:username", "input:password:password", "button:submit:"]);

  // Pengaturan tampilan tetap bisa dijangkau keyboard, hanya saja sesudah konten.
  await page.getByRole("radio", { name: "Terang" }).focus();
  await page.keyboard.press("Tab");
  await expect(page.getByRole("radio", { name: "Indonesia" })).toBeFocused();
});
