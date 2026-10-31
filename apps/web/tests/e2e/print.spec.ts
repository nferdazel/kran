import AxeBuilder from "@axe-core/playwright";

import { blockingViolations } from "./axe.js";
import { expect, test, type APIRequestContext, type Page } from "@playwright/test";
import { requireDatabase } from "./db.js";

/**
 * Cetak Fase 2 (T-094a/T-094b, D-127): browser print, bukan PDF server.
 *
 * Yang diuji:
 *  - dokumen slip/statement tampil di layar dengan data dari endpoint baca (bukan respons POST);
 *  - tombol Cetak memanggil `window.print` (di-stub: tidak ada dialog printer di CI);
 *  - dengan `emulateMedia({ media: "print" })` nav, toolbar, form, dan alert hilang, sedangkan
 *    isi dokumen tetap terlihat (bukti aturan `@media print` di `packages/ui`);
 *  - axe (mode **layar**) pada kedua halaman × 2 tema × 2 locale.
 *
 * Batas yang tidak diklaim: bukan bukti layout printer tertentu, bukan PDF resmi/arsip/tagged,
 * bukan audit cetak, bukan kop lembaga. `page.pdf()` tidak dipakai (bukan bukti layout).
 */

requireDatabase();

declare global {
  interface Window {
    __printCount?: number;
  }
}

// Port tetap dari playwright.config.ts (API e2e sengaja beda dari API dev).
const API = "http://127.0.0.1:8099";
const BRANCH = "e2e00000-0000-4000-8000-000000000001";
const MAKER = { username: "dev.maker", password: "rahasia-panjang-123" };
const CHECKER = { username: "dev.checker", password: "rahasia-panjang-123" };
const LOCALES = ["id", "en"] as const;
const THEMES = ["light", "dark"] as const;
// Rentang lebar: rekening fixture baru, jadi barisnya hanya milik run ini.
const RANGE = { from: "2000-01-01", to: "2099-12-31" };

type Locale = (typeof LOCALES)[number];
type Theme = (typeof THEMES)[number];

const T: Record<Locale, { slipHeading: string; statementHeading: string; print: string }> = {
  id: {
    slipHeading: "Slip transaksi tunai",
    statementHeading: "Statement rekening",
    print: "Cetak",
  },
  en: {
    slipHeading: "Cash transaction slip",
    statementHeading: "Account statement",
    print: "Print",
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

/** Tutup sesi OPEN yang tertinggal dari run sebelumnya (partial unique: satu OPEN per teller). */
async function closeLeftoverSession(request: APIRequestContext, cookie: string): Promise<void> {
  const current = await request.get(`${API}/api/v1/teller/sessions/current?branchId=${BRANCH}`, {
    headers: { Cookie: cookie },
  });
  if (current.status() !== 200) return;
  const session = (await current.json()) as { sessionId: string; openingFloat: string };
  const closed = await request.post(`${API}/api/v1/teller/sessions/${session.sessionId}/close`, {
    headers: { Cookie: cookie, "Idempotency-Key": `e2e-print-cleanup-${Date.now()}` },
    data: { countedCash: session.openingFloat },
  });
  expect([200, 409], `tutup sesi sisa: ${await closed.text()}`).toContain(closed.status());
}

type Fixture = {
  accountId: string;
  accountNo: string;
  cookie: string;
  transactionId: string;
};

/** Produk + party + rekening lewat API, lalu satu sesi kas dan satu setoran tunai. */
async function createCashFixture(request: APIRequestContext): Promise<Fixture> {
  const maker = await apiLogin(request, MAKER);
  const checker = await apiLogin(request, CHECKER);
  await closeLeftoverSession(request, maker);

  const suffix = `${Date.now()}`.slice(-9);
  const code = `E2EP${suffix}`;
  const headers = { Cookie: maker, "Idempotency-Key": `e2e-print-${suffix}` };

  const product = await request.post(`${API}/api/v1/products`, {
    headers: { Cookie: maker },
    data: {
      code,
      name: `Tabungan Cetak ${suffix}`,
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

  const approve = await request.post(
    `${API}/api/v1/products/${code}/versions/${draft!.versionId}/approve`,
    { headers: { Cookie: checker } },
  );
  expect(approve.status(), `setujui produk: ${await approve.text()}`).toBe(200);

  const party = await request.post(`${API}/api/v1/parties`, {
    headers,
    data: { kind: "PERSON", displayName: `Nasabah Cetak ${suffix}`, branchId: BRANCH },
  });
  expect(party.status(), `buat party: ${await party.text()}`).toBe(201);
  const partyId = ((await party.json()) as { partyId: string }).partyId;

  const account = await request.post(`${API}/api/v1/deposit/accounts`, {
    headers: { Cookie: maker, "Idempotency-Key": `e2e-print-account-${suffix}` },
    data: { partyId, productCode: code, branchId: BRANCH },
  });
  expect(account.status(), `buka rekening: ${await account.text()}`).toBe(201);
  const opened = (await account.json()) as { accountId: string; accountNo: string };

  const session = await request.post(`${API}/api/v1/teller/sessions`, {
    headers: { Cookie: maker, "Idempotency-Key": `e2e-print-session-${suffix}` },
    data: { branchId: BRANCH, openingFloat: "1000.00" },
  });
  expect([200, 201], `buka sesi: ${await session.text()}`).toContain(session.status());

  const cash = await request.post(`${API}/api/v1/teller/cash-transactions`, {
    headers: { Cookie: maker, "Idempotency-Key": `e2e-print-cash-${suffix}` },
    data: {
      accountId: opened.accountId,
      direction: "DEPOSIT",
      amount: "25.00",
      narration: "cetak uji",
    },
  });
  expect(cash.status(), `setor tunai: ${await cash.text()}`).toBe(201);
  const transactionId = ((await cash.json()) as { transactionId: string }).transactionId;

  return {
    accountId: opened.accountId,
    accountNo: opened.accountNo,
    cookie: maker,
    transactionId,
  };
}

/** Tempel cookie sesi hasil login API ke konteks browser (tanpa mengulang alur login UI). */
async function grantSession(page: Page, cookie: string): Promise<void> {
  const value = cookie.slice(cookie.indexOf("=") + 1);
  // Port/URL yang sama dengan `baseURL` playwright.config.ts.
  await page.context().addCookies([{ name: "kran_session", value, url: "http://127.0.0.1:4173" }]);
}

/** `window.print` di-stub: klik Cetak dihitung, bukan membuka dialog printer. */
async function stubPrint(page: Page): Promise<void> {
  await page.addInitScript(() => {
    window.__printCount = 0;
    window.print = () => {
      window.__printCount = (window.__printCount ?? 0) + 1;
    };
  });
}

async function prepare(page: Page, locale: Locale, theme: Theme): Promise<void> {
  await page.addInitScript(
    (init: { locale: string; theme: string }) => {
      localStorage.setItem("PARAGLIDE_LOCALE", init.locale);
      localStorage.setItem("kran-theme", init.theme);
    },
    { locale, theme },
  );
}

function blocking(results: Awaited<ReturnType<AxeBuilder["analyze"]>>): string[] {
  return blockingViolations(results.violations).map((violation) => violation.id);
}

test.describe.serial("cetak: slip & statement", () => {
  test("slip: dokumen tampil, Cetak dipanggil, nav/toolbar hilang saat print", async ({
    page,
    request,
  }) => {
    test.setTimeout(120_000);
    const fixture = await createCashFixture(request);
    await grantSession(page, fixture.cookie);
    await stubPrint(page);
    await prepare(page, "id", "light");

    await page.goto(`/app/print/slip/${fixture.transactionId}`);
    await expect(
      page.getByRole("heading", { level: 1, name: T.id.slipHeading }),
    ).toBeVisible();
    await expect(page.getByText(fixture.accountNo, { exact: true })).toBeVisible();
    await expect(page.getByText(fixture.transactionId, { exact: true })).toBeVisible();

    await page.getByRole("button", { name: T.id.print }).click();
    await expect.poll(() => page.evaluate(() => window.__printCount ?? 0)).toBe(1);

    await page.emulateMedia({ media: "print" });
    await expect(page.locator("nav")).toBeHidden();
    await expect(page.locator(".kran-print-toolbar")).toBeHidden();
    await expect(
      page.getByRole("heading", { level: 1, name: T.id.slipHeading }),
    ).toBeVisible();
    await expect(page.getByText(fixture.accountNo, { exact: true })).toBeVisible();
  });

  test("statement: tabel + total tampil, form hilang saat print", async ({ page, request }) => {
    test.setTimeout(120_000);
    const fixture = await createCashFixture(request);
    await grantSession(page, fixture.cookie);
    await stubPrint(page);
    await prepare(page, "id", "light");

    await page.goto(
      `/app/print/statement/${fixture.accountId}?from=${RANGE.from}&to=${RANGE.to}`,
    );
    await expect(
      page.getByRole("heading", { level: 1, name: T.id.statementHeading }),
    ).toBeVisible();
    await expect(page.getByText(fixture.accountNo, { exact: true })).toBeVisible();
    // Satu baris setoran tunai: masuk (+), nominal 25.000,00 pada locale id.
    await expect(page.locator("table tbody tr")).toHaveCount(1);
    await expect(page.locator("table tbody tr").first()).toContainText("Masuk");
    await expect(page.locator("table tfoot")).toContainText("Total masuk");

    await page.getByRole("button", { name: T.id.print }).click();
    await expect.poll(() => page.evaluate(() => window.__printCount ?? 0)).toBe(1);

    await page.emulateMedia({ media: "print" });
    await expect(page.locator("nav")).toBeHidden();
    await expect(page.locator(".kran-print-toolbar")).toBeHidden();
    await expect(page.locator(".kran-form")).toBeHidden();
    await expect(page.locator("table tbody tr")).toHaveCount(1);
  });

  test("axe: slip + statement × 2 tema × 2 locale (mode layar)", async ({ page, request }) => {
    test.setTimeout(300_000);
    const fixture = await createCashFixture(request);
    await grantSession(page, fixture.cookie);
    await stubPrint(page);

    for (const locale of LOCALES) {
      for (const theme of THEMES) {
        await prepare(page, locale, theme);

        await page.goto(`/app/print/slip/${fixture.transactionId}`);
        await expect(
          page.getByRole("heading", { level: 1, name: T[locale].slipHeading }),
        ).toBeVisible();
        const slipResults = await new AxeBuilder({ page }).analyze();
        expect(blocking(slipResults), `${locale}/${theme} slip: ${blocking(slipResults).join(", ")}`)
          .toEqual([]);

        await page.goto(
          `/app/print/statement/${fixture.accountId}?from=${RANGE.from}&to=${RANGE.to}`,
        );
        await expect(
          page.getByRole("heading", { level: 1, name: T[locale].statementHeading }),
        ).toBeVisible();
        const statementResults = await new AxeBuilder({ page }).analyze();
        expect(
          blocking(statementResults),
          `${locale}/${theme} statement: ${blocking(statementResults).join(", ")}`,
        ).toEqual([]);
      }
    }
  });
});
