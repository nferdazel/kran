import { expect, test, type Page } from "@playwright/test";
import { requireDatabase } from "./db.js";

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

requireDatabase();

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

/**
 * Zoom 200% (T-144): 1366/2 = 683 CSS px. Pada lebar itu shell harus jatuh ke **satu kolom** (sidebar
 * di atas, bukan di samping) dan tabel buku besar tetap tabel sungguhan yang menggulir di dalam
 * region-nya — bukan berubah menjadi kartu atau memperlebar halaman.
 */
test.describe("zoom 200%", () => {
  test.use({ viewport: { width: 683, height: 384 } });

  test("1366×768 @200%: shell satu kolom, tabel tetap tabel dengan gulir di region", async ({
    page,
  }) => {
    await prepare(page);
    await login(page);

    const grid = page.getByRole("grid");
    await expect(grid).toBeVisible();
    await expect(grid.locator("tbody tr").first()).toBeVisible();

    // 1. Shell satu kolom: grid-template-columns hanya satu track (sidebar tidak di samping isi).
    const tracks = await page.locator(".kran-shell").evaluate((el) =>
      getComputedStyle(el).gridTemplateColumns.trim().split(/\s+/),
    );
    expect(tracks, "shell 200% harus satu kolom").toHaveLength(1);

    // 2. Halaman tidak melebar mendatar.
    const pageOverflow = await page.evaluate(
      () => document.documentElement.scrollWidth - document.documentElement.clientWidth,
    );
    expect(pageOverflow).toBeLessThanOrEqual(1);

    // 3. Tabel tetap tabel di dalam region bergulir berlabel (bukan kartu per baris).
    const region = page.locator(".ledger-region");
    await expect(region).toBeVisible();
    expect(await region.evaluate((el) => getComputedStyle(el).overflowX)).toBe("auto");
    expect(await page.locator(".ledger-table").evaluate((el) => getComputedStyle(el).display))
      .toBe("table");

    // 4. Tabel masih bisa difokus dan dinavigasi keyboard pada ukuran ini.
    await page.locator(".kran-filter-bar .kran-filter-button").last().focus();
    await page.keyboard.press("Tab");
    await expect(grid).toBeFocused();
    await page.keyboard.press("ArrowRight");
    await expect(grid).toHaveAttribute("aria-activedescendant", "ledger-cell-0-1");
  });
});
