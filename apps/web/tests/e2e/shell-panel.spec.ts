import { requireDatabase } from "./db.js";
import { expect, test, type Locator, type Page } from "@playwright/test";

/**
 * Panel off-canvas di bawah 1024px (T-285 acceptance item 2).
 *
 * `AppShell.svelte` sudah menulis sendiri trap-nya: panel ditutup dengan `visibility: hidden`
 * (bukan sekadar transform) sehingga link-nya keluar dari tab order, membuka panel memindah fokus
 * ke elemen pertama, Tab membungkus di dalam panel, dan Escape menutup lalu mengembalikan fokus ke
 * tombol menu. Komentar lama di `packages/ui/tests/shell.test.ts` menyebut perilaku ini "covered by
 * the Playwright a11y gate" — sebelum berkas ini, klaim itu belum benar: nol spec yang
 * menjalankannya, jadi trap yang rusak tetap hijau.
 *
 * Yang dibuktikan (semua di app nyata, sesi nyata, viewport 390×844):
 *   1. saat load: panel tidak visible, tombol menu visible dengan `aria-expanded="false"`;
 *   2. buka: panel + scrim visible, `aria-expanded="true"`, fokus pindah ke elemen pertama panel;
 *   3. Tab: fokus tidak pernah keluar panel, dan Tab dari elemen terakhir membungkus ke pertama;
 *   4. Shift+Tab dari elemen pertama membungkus ke elemen terakhir;
 *   5. Escape: panel tertutup, `aria-expanded="false"`, fokus persis di tombol menu.
 *
 * Batas: tanpa `KRAN_DATABASE_URL` berkas ini dilewati (sama dengan spec app lain), karena login
 * butuh API + DB dev.
 */

requireDatabase();

const MAKER = { username: "dev.maker", password: "rahasia-panjang-123" };
const NARROW = { width: 390, height: 844 };

/** Locale + tema sebelum render (strategi Paraglide `localStorage`, sama dengan spec lain). */
async function prepare(page: Page): Promise<void> {
  await page.addInitScript(() => {
    localStorage.setItem("PARAGLIDE_LOCALE", "id");
    localStorage.setItem("kran-theme", "light");
  });
}

/** Login lewat keyboard-only, pola yang sama dengan `ledger.spec.ts`. */
async function login(page: Page): Promise<void> {
  await page.goto("/login");
  await expect(page.getByRole("heading", { level: 1, name: "Masuk" })).toBeVisible();
  await page.getByLabel("Nama pengguna", { exact: true }).focus();
  await page.keyboard.type(MAKER.username);
  await page.keyboard.press("Tab");
  await page.keyboard.type(MAKER.password);
  await page.keyboard.press("Enter");
  await expect(page).toHaveURL(/\/app\/ledger$/);
  await expect(page.getByRole("heading", { level: 1, name: "Saldo buku besar" })).toBeVisible();
}

/** Elemen focusable panel, urutan DOM yang sama dengan trap di `AppShell.svelte`. */
async function panelFocusableCount(page: Page): Promise<number> {
  return page.locator(".shell__panel").evaluate((panel) => {
    return [
      ...panel.querySelectorAll<HTMLElement>(
        'a[href], button:not([disabled]), input:not([disabled]), select:not([disabled]), textarea:not([disabled]), [tabindex]:not([tabindex="-1"])',
      ),
    ].filter((element) => element.offsetParent !== null).length;
  });
}

/** True bila `document.activeElement` ada di dalam panel. */
async function focusInPanel(page: Page): Promise<boolean> {
  return page.evaluate(() => {
    const panel = document.querySelector(".shell__panel");
    const active = document.activeElement;
    return panel !== null && active instanceof Node && panel.contains(active);
  });
}

/** True bila `document.activeElement` adalah elemen focusable pertama/terakhir panel. */
async function focusIsPanelEdge(page: Page, edge: "first" | "last"): Promise<boolean> {
  return page.locator(".shell__panel").evaluate((panel, which) => {
    const focusables = [
      ...panel.querySelectorAll<HTMLElement>(
        'a[href], button:not([disabled]), input:not([disabled]), select:not([disabled]), textarea:not([disabled]), [tabindex]:not([tabindex="-1"])',
      ),
    ].filter((element) => element.offsetParent !== null);
    const target = which === "first" ? focusables[0] : focusables[focusables.length - 1];
    return target !== undefined && document.activeElement === target;
  }, edge);
}

test.use({ viewport: NARROW });

test("panel off-canvas <1024px: trap Tab, Shift+Tab dan Escape", async ({ page }) => {
  await prepare(page);
  await login(page);

  const menuButton: Locator = page.locator("[data-shell-menu-button]");
  const panel: Locator = page.locator(".shell__panel");
  const scrim: Locator = page.locator(".shell__scrim");

  // 1. Terbuka dalam keadaan tertutup: panel benar-benar hilang (visibility: hidden), bukan
  //    sekadar di luar layar — link di dalamnya tidak boleh jadi tab-stop hantu.
  await expect(panel).toBeHidden();
  await expect(menuButton).toBeVisible();
  await expect(menuButton).toHaveAttribute("aria-expanded", "false");
  await expect(menuButton).toHaveAccessibleName(/\S/);
  await expect(scrim).toHaveCount(0);

  // 2. Membuka panel: scrim muncul dan fokus masuk ke elemen focusable pertama.
  await menuButton.click();
  await expect(panel).toBeVisible();
  await expect(menuButton).toHaveAttribute("aria-expanded", "true");
  await expect(scrim).toBeVisible();
  expect(await focusInPanel(page)).toBe(true);
  expect(await focusIsPanelEdge(page, "first")).toBe(true);

  // 3. Tab sebanyak jumlah focusable: fokus tidak pernah keluar panel, lalu membungkus ke pertama.
  const focusableCount = await panelFocusableCount(page);
  expect(focusableCount).toBeGreaterThan(1);
  for (let step = 0; step < focusableCount; step += 1) {
    await page.keyboard.press("Tab");
    expect(await focusInPanel(page)).toBe(true);
  }
  expect(await focusIsPanelEdge(page, "first")).toBe(true);

  // 4. Shift+Tab dari elemen pertama membungkus ke elemen terakhir (arah sebaliknya).
  await page.keyboard.press("Shift+Tab");
  expect(await focusInPanel(page)).toBe(true);
  expect(await focusIsPanelEdge(page, "last")).toBe(true);

  // 5. Escape menutup panel dan mengembalikan fokus persis ke tombol menu.
  await page.keyboard.press("Escape");
  await expect(panel).toBeHidden();
  await expect(menuButton).toHaveAttribute("aria-expanded", "false");
  await expect(scrim).toHaveCount(0);
  await expect(menuButton).toBeFocused();
});
