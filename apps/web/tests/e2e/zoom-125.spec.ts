import { expect, test, type Page } from "@playwright/test";

/**
 * Target ukuran kerja DESIGN §4/§12: **1366×768 pada zoom 100–125%**, tanpa gulir mendatar di
 * tingkat halaman. Zoom peramban tidak bisa disetel Playwright, jadi zoom diemulasi lewat viewport
 * dalam **CSS px** hasil bagi: 1366 / 1.25 ≈ 1093 dan 768 / 1.25 ≈ 614 (project `zoom-125` di
 * `playwright.config.ts`; `test.use` di bawah menjaga berkas ini tetap benar bila dijalankan dengan
 * project lain, mis. `--project=chromium`).
 *
 * Yang dibuktikan: shell tidak menggulir mendatar, tabel buku besar tetap terpakai — kolom kode
 * tetap terlihat saat tabel digulir mendatar di dalam region-nya (kolom kode sticky), bukan
 * menggeser halaman.
 *
 * Batas: butuh API + DB dev (seed `0003_dev_ledger.sql`); tanpa `KRAN_DATABASE_URL` dilewati.
 */

test.skip(!process.env.KRAN_DATABASE_URL, "KRAN_DATABASE_URL kosong — API e2e tidak dijalankan");

test.use({ viewport: { width: 1093, height: 614 } });

const MAKER = { username: "dev.maker", password: "rahasia-panjang-123" };
/** Teks katalog (id) — penanda test deterministik, bukan tebakan bahasa peramban. */
const TEXT = {
  loginTitle: "Masuk",
  username: "Nama pengguna",
  ledgerTitle: "Saldo buku besar",
} as const;

async function prepare(page: Page): Promise<void> {
  await page.addInitScript(() => {
    localStorage.setItem("PARAGLIDE_LOCALE", "id");
    localStorage.setItem("kran-theme", "light");
  });
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

test("1366×768 @125%: tanpa gulir mendatar halaman dan tabel tetap terpakai", async ({ page }) => {
  await prepare(page);
  await login(page);

  const grid = page.getByRole("grid");
  await expect(grid).toBeVisible();
  await expect(grid.locator("tbody tr").first()).toBeVisible();

  // 1. Tidak ada gulir mendatar di tingkat dokumen.
  const pageOverflow = await page.evaluate(
    () => document.documentElement.scrollWidth - document.documentElement.clientWidth,
  );
  expect(pageOverflow, "shell/ledger tidak boleh melebarkan halaman secara mendatar").toBeLessThanOrEqual(
    1,
  );

  // 2. Tabel yang lebar digulir di dalam region berlabel, bukan menggeser halaman.
  const region = page.locator(".ledger-region");
  await expect(region).toBeVisible();
  const overflowX = await region.evaluate((el) => getComputedStyle(el).overflowX);
  expect(overflowX).toBe("auto");

  // 3. Kolom kode sticky: setelah digulir penuh ke kanan, sel kode masih di tepi kiri region.
  const metrics = await region.evaluate((el) => ({
    scrollWidth: el.scrollWidth,
    clientWidth: el.clientWidth,
  }));
  if (metrics.scrollWidth > metrics.clientWidth) {
    await region.evaluate((el) => {
      el.scrollLeft = el.scrollWidth;
    });
    const codeCell = page.locator(".ledger-table tbody th.ledger-code").first();
    const codePosition = await codeCell.evaluate((el) => getComputedStyle(el).position);
    expect(codePosition).toBe("sticky");
    const codeBox = await codeCell.boundingBox();
    const regionBox = await region.boundingBox();
    expect(codeBox).not.toBeNull();
    expect(regionBox).not.toBeNull();
    expect(codeBox!.x).toBeLessThanOrEqual(regionBox!.x + 2);
  }

  // 4. Keyboard tetap bisa menjangkau tabel pada ukuran ini.
  await page.locator(".kran-filter-bar .kran-filter-button").last().focus();
  await page.keyboard.press("Tab");
  await expect(grid).toBeFocused();
  await page.keyboard.press("ArrowRight");
  await expect(grid).toHaveAttribute("aria-activedescendant", "ledger-cell-0-1");
});
