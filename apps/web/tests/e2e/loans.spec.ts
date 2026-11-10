import AxeBuilder from "@axe-core/playwright";

import { blockingViolations } from "./axe.js";
import { requireDatabase } from "./db.js";
import { expect, test, type APIRequestContext, type Page } from "@playwright/test";

/**
 * Layar pinjaman (T-170): daftar → detail → kembali, plus gate axe pada kedua layar.
 *
 * Fixture dibuat lewat API setiap test, bukan dari seed: akad yang dilihat layar harus benar-benar
 * melewati jalur tulis (submit → approve → disburse), supaya tabel jadwal dan saldo yang tampil
 * adalah hasil perhitungan server, bukan baris yang dikarang untuk tampilan. Yang datang dari seed
 * (`packs/base/seed/0006_dev_lending.sql`) hanya versi produk — katalog pinjaman belum punya rute
 * API.
 *
 * Akun: `dev.loans` (`lending_maker`: submit + disburse + read), `dev.console` (`platform_admin`,
 * penyetuju), `dev.maker`/`dev.checker` untuk produk simpanan + party + rekening (pola yang sama
 * dengan spec teller).
 */

requireDatabase();

const API = "http://127.0.0.1:8099";
const BRANCH = "e2e00000-0000-4000-8000-000000000001";
const PASSWORD = "rahasia-panjang-123";
const MAKER = { username: "dev.maker", password: PASSWORD };
const CHECKER = { username: "dev.checker", password: PASSWORD };
const LOANS = { username: "dev.loans", password: PASSWORD };
const CONSOLE = { username: "dev.console", password: PASSWORD };
/** md5('dev|lending-product-version') — versi produk dari seed dev. */
const LOAN_VERSION = "d13adf33-8c2d-453d-a16e-0ffa4b442f54";
const LOCALES = ["id", "en"] as const;
const THEMES = ["light", "dark"] as const;

type Locale = (typeof LOCALES)[number];

type Text = {
  listTitle: string;
  detailTitle: string;
  open: string;
  back: string;
  scheduleRegion: string;
  colPrincipal: string;
  schedulePrincipal: string;
  detailPrincipal: string;
};

const T: Record<Locale, Text> = {
  id: {
    listTitle: "Pinjaman",
    detailTitle: "Detail pinjaman",
    open: "Buka",
    back: "Kembali ke daftar pinjaman",
    scheduleRegion: "Tabel: Jadwal aktif",
    colPrincipal: "Pokok (IDR)",
    schedulePrincipal: "Pokok (IDR)",
    detailPrincipal: "Pokok akad (IDR)",
  },
  en: {
    listTitle: "Loans",
    detailTitle: "Loan detail",
    open: "Open",
    back: "Back to loan list",
    scheduleRegion: "Table: Active schedule",
    colPrincipal: "Principal (IDR)",
    schedulePrincipal: "Principal (IDR)",
    detailPrincipal: "Agreed principal (IDR)",
  },
};

function todayIso(): string {
  return new Date().toISOString().slice(0, 10);
}

async function apiLogin(
  request: APIRequestContext,
  user: { username: string; password: string },
): Promise<string> {
  const response = await request.post(`${API}/api/v1/auth/login`, {
    data: { username: user.username, password: user.password },
  });
  expect(response.status(), `login ${user.username}`).toBe(200);
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

function prepare(page: Page, locale: Locale, theme: string): Promise<unknown> {
  return page.addInitScript(
    (init: { locale: string; theme: string }) => {
      localStorage.setItem("PARAGLIDE_LOCALE", init.locale);
      localStorage.setItem("kran-theme", init.theme);
    },
    { locale, theme },
  );
}

type Fixture = { loanId: string; partyId: string };

/**
 * Akad `ACTIVE` yang sudah dicairkan, dibuat sepenuhnya lewat API.
 *
 * Pencairan menulis jadwal versi 1 + saldo, jadi detail layar punya tabel jadwal dan sisa pokok
 * yang nyata. Nominal kecil (1.200.000) supaya jelas di bawah plafon parameter.
 */
async function createActiveLoan(request: APIRequestContext): Promise<Fixture> {
  const suffix = `${Date.now()}`.slice(-9);
  const code = `E2E${suffix}`;
  const maker = await apiLogin(request, MAKER);
  const checker = await apiLogin(request, CHECKER);
  const loans = await apiLogin(request, LOANS);
  const console = await apiLogin(request, CONSOLE);
  const headers = { Cookie: maker, "Idempotency-Key": `e2e-loans-${suffix}` };

  const product = await request.post(`${API}/api/v1/products`, {
    headers: { Cookie: maker },
    data: {
      code,
      name: `Tabungan Pinjaman E2E ${suffix}`,
      productType: "SAVINGS",
      effectiveFrom: todayIso(),
      bindings: { "product.savings.min_balance": "0.00" },
    },
  });
  expect(product.status(), `buat produk: ${await product.text()}`).toBe(201);

  const detail = await request.get(`${API}/api/v1/products/${code}`, {
    headers: { Cookie: maker },
  });
  expect(detail.status()).toBe(200);
  const versions = (await detail.json()) as { versions: { versionId: string; status: string }[] };
  const draft = versions.versions.find((version) => version.status === "DRAFT");
  expect(draft, "versi DRAFT hasil pembuatan produk").toBeDefined();

  const approveProduct = await request.post(
    `${API}/api/v1/products/${code}/versions/${draft!.versionId}/approve`,
    { headers: { Cookie: checker } },
  );
  expect(approveProduct.status(), `setujui produk: ${await approveProduct.text()}`).toBe(200);

  const party = await request.post(`${API}/api/v1/parties`, {
    headers,
    data: { kind: "PERSON", displayName: `Peminjam E2E ${suffix}`, branchId: BRANCH },
  });
  expect(party.status(), `buat party: ${await party.text()}`).toBe(201);
  const partyId = ((await party.json()) as { partyId: string }).partyId;

  const account = await request.post(`${API}/api/v1/deposit/accounts`, {
    headers: { Cookie: maker, "Idempotency-Key": `e2e-loans-account-${suffix}` },
    data: { partyId, productCode: code, branchId: BRANCH },
  });
  expect(account.status(), `buka rekening: ${await account.text()}`).toBe(201);
  const accountId = ((await account.json()) as { accountId: string }).accountId;

  const submitted = await request.post(`${API}/api/v1/lending/loans`, {
    headers: { Cookie: loans },
    data: { partyId, productVersionId: LOAN_VERSION, principal: "1200000.00" },
  });
  expect(submitted.status(), `ajukan pinjaman: ${await submitted.text()}`).toBe(201);
  const loanId = ((await submitted.json()) as { loanId: string }).loanId;

  // Penyetuju harus orang lain (empat mata), jadi approve dilakukan `dev.console`.
  const approved = await request.post(`${API}/api/v1/lending/loans/${loanId}/approve`, {
    headers: { Cookie: console },
    data: {},
  });
  expect(approved.status(), `setujui pinjaman: ${await approved.text()}`).toBe(200);

  const disbursed = await request.post(`${API}/api/v1/lending/loans/${loanId}/disburse`, {
    headers: { Cookie: loans, "Idempotency-Key": `e2e-loans-disburse-${suffix}` },
    data: { accountId },
  });
  expect(disbursed.status(), `cairkan pinjaman: ${await disbursed.text()}`).toBe(200);

  return { loanId, partyId };
}

test.describe("pinjaman: daftar & detail", () => {
  test("kosong: no-data dan no-match memakai kalimat berbeda", async ({ page, request }) => {
    const cookie = await apiLogin(request, LOANS);
    await browserLogin(page, cookie);
    await prepare(page, "id", "light");
    // Daftar kosong dari server sungguhan tidak bisa dijamin setelah spec lain membuat akad,
    // jadi respons daftar dipatok kosong; yang diuji adalah cabang tampilan, bukan query API.
    await page.route("**/api/v1/lending/loans**", (route) =>
      route.fulfill({
        status: 200,
        contentType: "application/json",
        body: JSON.stringify({ items: [] }),
      }),
    );

    await page.goto("/app/loans");
    await expect(page.getByText("Belum ada pinjaman. Ajukan pinjaman pertama.")).toBeVisible();

    await page.getByLabel("ID anggota").fill("11111111-1111-4111-8111-111111111111");
    await page.getByRole("button", { name: "Tampilkan" }).click();

    await expect(page.getByText("Tidak ada pinjaman yang cocok.")).toBeVisible();
    await expect(page.getByRole("button", { name: "Hapus filter" })).toBeVisible();
    await expect(page.getByText("Belum ada pinjaman. Ajukan pinjaman pertama.")).toHaveCount(0);
  });

  test("axe: daftar dan detail × 2 tema × 2 locale × 1440/360", async ({ page, request }) => {
    test.setTimeout(360_000);
    const loan = await createActiveLoan(request);
    await browserLogin(page, await apiLogin(request, LOANS));

    for (const locale of LOCALES) {
      for (const width of [1440, 360] as const) {
        for (const theme of THEMES) {
          await page.setViewportSize({ width, height: 900 });
          await prepare(page, locale, theme);

          await page.goto("/app/loans");
          await expect(
            page.getByRole("heading", { level: 1, name: T[locale].listTitle }),
          ).toBeVisible();
          // Baris akad baru harus terlihat: tanpa ini axe boleh hijau pada tabel kosong.
          await expect(page.getByRole("link", { name: T[locale].open }).first()).toBeVisible();
          const listResults = await new AxeBuilder({ page }).analyze();
          const listBlocking = blockingViolations(listResults.violations);
          expect(
            listBlocking,
            `/app/loans ${locale}/${theme}/${width}: ${listBlocking.map((violation) => violation.id).join(", ")}`,
          ).toEqual([]);

          await page.goto(`/app/loans/${loan.loanId}`);
          await expect(
            page.getByRole("heading", { level: 1, name: T[locale].detailTitle }),
          ).toBeVisible();
          await expect(page.getByRole("region", { name: T[locale].scheduleRegion })).toBeVisible();
          const detailResults = await new AxeBuilder({ page }).analyze();
          const detailBlocking = blockingViolations(detailResults.violations);
          expect(
            detailBlocking,
            `/app/loans/{loanId} ${locale}/${theme}/${width}: ${detailBlocking.map((violation) => violation.id).join(", ")}`,
          ).toEqual([]);
        }
      }
    }
  });

  test("mata uang: unit sekali di header, sel tanpa unit", async ({ page, request }) => {
    test.setTimeout(180_000);
    const loan = await createActiveLoan(request);
    await browserLogin(page, await apiLogin(request, LOANS));

    for (const locale of LOCALES) {
      await prepare(page, locale, "light");

      await page.goto("/app/loans");
      await expect(
        page.getByRole("columnheader", { name: T[locale].colPrincipal, exact: true }),
      ).toBeVisible();
      const listHeaders = await page.locator("thead th").allTextContents();
      for (const header of listHeaders) {
        expect(header.match(/IDR/g)?.length ?? 0, `header "${header}"`).toBeLessThanOrEqual(1);
      }
      const listCells = await page.locator("td.kran-money").allTextContents();
      expect(listCells.length, "sel uang pada daftar").toBeGreaterThan(0);
      for (const cell of listCells) {
        expect(cell.trim(), `sel daftar "${cell}"`).toMatch(/^[\d.,]+$/);
      }

      await page.goto(`/app/loans/${loan.loanId}`);
      const schedule = page.getByRole("region", { name: T[locale].scheduleRegion });
      await expect(
        schedule.getByRole("columnheader", { name: T[locale].schedulePrincipal, exact: true }),
      ).toBeVisible();
      const scheduleHeaders = await schedule.locator("thead th").allTextContents();
      expect(
        scheduleHeaders.filter((header) => header.trim().endsWith(" (IDR)")).length,
        `header jadwal ber-IDR: ${scheduleHeaders.join(" | ")}`,
      ).toBe(4);

      await expect(page.locator("dl.kran-facts dt", { hasText: T[locale].detailPrincipal })).toBeVisible();
      const factLabels = await page.locator("dl.kran-facts dt").allTextContents();
      expect(
        factLabels.filter((label) => label.trim().endsWith(" (IDR)")).length,
        `label fakta ber-IDR: ${factLabels.join(" | ")}`,
      ).toBeGreaterThanOrEqual(4);

      const moneyCells = await page.locator("dl.kran-facts dd, td.kran-money").allTextContents();
      for (const cell of moneyCells) {
        expect(cell, `sel detail "${cell}"`).not.toMatch(/IDR|Rp/);
      }
    }
  });

  test("keyboard-only: daftar → detail → kembali tanpa tetikus", async ({ page, request }) => {
    test.setTimeout(180_000);
    const loan = await createActiveLoan(request);
    await browserLogin(page, await apiLogin(request, LOANS));
    await prepare(page, "id", "light");

    await page.goto("/app/loans");
    const open = page.getByRole("link", { name: T.id.open, exact: true }).first();
    await open.focus();
    await expect(open).toBeFocused();
    await page.keyboard.press("Enter");

    await expect(page).toHaveURL(new RegExp(`/app/loans/${loan.loanId}$`));
    await expect(page.getByRole("heading", { level: 1, name: T.id.detailTitle })).toBeVisible();

    // Jadwal aktif dari pencairan: 12 angsuran, bukan tabel kosong yang lolos tanpa arti.
    const schedule = page.getByRole("region", { name: T.id.scheduleRegion });
    await expect(schedule).toBeVisible();
    await expect(schedule.getByRole("row")).toHaveCount(13);

    const back = page.getByRole("link", { name: T.id.back, exact: true });
    await back.focus();
    await expect(back).toBeFocused();
    await page.keyboard.press("Enter");
    await expect(page).toHaveURL(/\/app\/loans$/);
    await expect(page.getByRole("heading", { level: 1, name: T.id.listTitle })).toBeVisible();
  });
});
