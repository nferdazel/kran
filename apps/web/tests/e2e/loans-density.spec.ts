import AxeBuilder from "@axe-core/playwright";

import { blockingViolations } from "./axe.js";
import { requireDatabase } from "./db.js";
import { expect, test, type APIRequestContext, type Page } from "@playwright/test";

/**
 * Kepadatan daftar pinjaman (T-293): baris 40px, tanggal satu baris, anggota dua baris.
 *
 * Angka T-288 tidak bisa diturunkan lagi karena spec pengukurnya tidak pernah di-commit, jadi
 * berkas ini ikut di-commit: satu baris JSON per kombinasi lebar/tema dengan bentuk yang sama
 * (`route`, `theme`, `physicalWidth`, `rowHeight`, `headerHeight`, `pageOverflow`). Ambangnya
 * nyata, bukan laporan: baris > 44px atau tanggal pecah baris = gagal.
 *
 * Fixture dibuat lewat API (jalur tulis sungguhan, sama seperti `loans.spec.ts`), dengan satu
 * nama anggota 60 karakter supaya elipsis kolom dua tingkat benar-benar terbukti.
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
const THEMES = ["light", "dark"] as const;
const WIDTHS = [1440, 360] as const;
/** 60 karakter: cukup panjang untuk memaksa elipsis di kolom anggota pada kedua lebar. */
const LONG_NAME = "Peminjam Dengan Nama Sangat Panjang Sekali Enam Puluh Karakter";

test.use({ deviceScaleFactor: 1 });

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

function prepare(page: Page, theme: string): Promise<unknown> {
  return page.addInitScript(
    (init: { theme: string }) => {
      localStorage.setItem("PARAGLIDE_LOCALE", "id");
      localStorage.setItem("kran-theme", init.theme);
    },
    { theme },
  );
}

type Fixture = { loanId: string; partyId: string };

/** Akad `ACTIVE` tercair dengan nama anggota panjang, dibuat seluruhnya lewat API. */
async function createActiveLoan(request: APIRequestContext, displayName: string): Promise<Fixture> {
  const suffix = `${Date.now()}`.slice(-9);
  const code = `E2D${suffix}`;
  const maker = await apiLogin(request, MAKER);
  const checker = await apiLogin(request, CHECKER);
  const loans = await apiLogin(request, LOANS);
  const console = await apiLogin(request, CONSOLE);
  const headers = { Cookie: maker, "Idempotency-Key": `e2e-density-${suffix}` };

  const product = await request.post(`${API}/api/v1/products`, {
    headers: { Cookie: maker },
    data: {
      code,
      name: `Tabungan Kepadatan E2E ${suffix}`,
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
    data: { kind: "PERSON", displayName, branchId: BRANCH },
  });
  expect(party.status(), `buat party: ${await party.text()}`).toBe(201);
  const partyId = ((await party.json()) as { partyId: string }).partyId;

  const account = await request.post(`${API}/api/v1/deposit/accounts`, {
    headers: { Cookie: maker, "Idempotency-Key": `e2e-density-account-${suffix}` },
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

  const approved = await request.post(`${API}/api/v1/lending/loans/${loanId}/approve`, {
    headers: { Cookie: console },
    data: {},
  });
  expect(approved.status(), `setujui pinjaman: ${await approved.text()}`).toBe(200);

  const disbursed = await request.post(`${API}/api/v1/lending/loans/${loanId}/disburse`, {
    headers: { Cookie: loans, "Idempotency-Key": `e2e-density-disburse-${suffix}` },
    data: { accountId },
  });
  expect(disbursed.status(), `cairkan pinjaman: ${await disbursed.text()}`).toBe(200);

  return { loanId, partyId };
}

type Metrics = {
  rowHeight: number;
  headerHeight: number;
  pageOverflow: number;
  dateRects: number;
  dateWhiteSpace: string;
  nameClient: number;
  nameScroll: number;
  nameLines: number;
};

/** Angka satu baris untuk baris pinjaman fixture di viewport sekarang. */
async function measure(page: Page, loanId: string): Promise<Metrics> {
  return page.evaluate((wanted: string) => {
    const row = [...document.querySelectorAll("tbody tr")].find((candidate) =>
      candidate.querySelector(`a[href$="${wanted}"]`),
    );
    if (!row) throw new Error(`baris pinjaman ${wanted} tidak ada di tabel`);

    // Kolom: akad, anggota, pokok, status, tanggal cair, aksi.
    const dateCell = row.children[4] as HTMLElement;
    const memberCell = row.children[1];
    if (!memberCell) throw new Error("kolom anggota tidak ada");

    const dateText = dateCell.querySelector(".kran-table__primary") ?? dateCell;
    const dateRange = document.createRange();
    dateRange.selectNodeContents(dateText);
    const name = memberCell.querySelector(".kran-table__primary") as HTMLElement;
    const header = document.querySelector("thead tr") as HTMLElement;

    return {
      rowHeight: (row as HTMLElement).getBoundingClientRect().height,
      headerHeight: header.getBoundingClientRect().height,
      pageOverflow: document.documentElement.scrollWidth - document.documentElement.clientWidth,
      dateRects: dateRange.getClientRects().length,
      dateWhiteSpace: getComputedStyle(dateCell).whiteSpace,
      nameClient: name.clientWidth,
      nameScroll: name.scrollWidth,
      nameLines: Math.round(
        name.getBoundingClientRect().height / parseFloat(getComputedStyle(name).lineHeight),
      ),
    };
  }, loanId);
}

test.describe("pinjaman: kepadatan baris", () => {
  test("baris <= 44px, tanggal satu baris, anggota dua baris berelipsis", async ({
    page,
    request,
  }) => {
    test.setTimeout(240_000);
    const loan = await createActiveLoan(request, LONG_NAME);
    await browserLogin(page, await apiLogin(request, LOANS));

    for (const width of WIDTHS) {
      for (const theme of THEMES) {
        await prepare(page, theme);
        await page.setViewportSize({ width, height: 900 });
        await page.goto("/app/loans");
        await expect(page.getByRole("heading", { level: 1, name: "Pinjaman" })).toBeVisible();
        const row = page.locator("tbody tr").filter({
          has: page.locator(`a[href$="${loan.loanId}"]`),
        });
        await expect(row).toBeVisible();

        const metrics = await measure(page, loan.loanId);
        console.log(
          JSON.stringify({
            route: "/app/loans",
            theme,
            physicalWidth: width,
            rowHeight: metrics.rowHeight,
            headerHeight: metrics.headerHeight,
            pageOverflow: metrics.pageOverflow,
          }),
        );

        expect(metrics.rowHeight, `baris ${width}/${theme}`).toBeLessThanOrEqual(44);
        expect(metrics.headerHeight, `header ${width}/${theme}`).toBeLessThanOrEqual(44);
        expect(metrics.dateRects, `tanggal ${width}/${theme} harus satu baris`).toBe(1);
        expect(metrics.dateWhiteSpace, `tanggal ${width}/${theme} nowrap`).toBe("nowrap");
        // Nama 60 karakter: satu baris terpotong, bukan tiga baris yang menaikkan tinggi.
        expect(metrics.nameLines, `nama ${width}/${theme} satu baris`).toBe(1);
        expect(metrics.nameScroll, `nama ${width}/${theme} berelipsis`).toBeGreaterThan(
          metrics.nameClient,
        );

        await page.screenshot({
          path: `../../.local/qa/results/T-293-web-loans-${width}-${theme}.png`,
          fullPage: false,
        });
      }
    }
  });

  test("axe: /app/loans × 2 lebar × 2 tema", async ({ page, request }) => {
    test.setTimeout(240_000);
    const loan = await createActiveLoan(request, `Anggota Axe ${`${Date.now()}`.slice(-9)}`);
    await browserLogin(page, await apiLogin(request, LOANS));

    for (const width of WIDTHS) {
      for (const theme of THEMES) {
        await prepare(page, theme);
        await page.setViewportSize({ width, height: 900 });
        await page.goto("/app/loans");
        await expect(
          page.locator("tbody tr").filter({ has: page.locator(`a[href$="${loan.loanId}"]`) }),
        ).toBeVisible();

        const results = await new AxeBuilder({ page }).analyze();
        const blocking = blockingViolations(results.violations);
        expect(
          blocking,
          `/app/loans ${width}/${theme}: ${blocking.map((violation) => violation.id).join(", ")}`,
        ).toEqual([]);
      }
    }
  });
});
