import AxeBuilder from "@axe-core/playwright";
import { expect, test, type APIRequestContext, type Page } from "@playwright/test";
import { requireDatabase } from "./db.js";

/**
 * Teller Fase 2 (T-109): alur nyata buka sesi → setor → tutup, keyboard-only, plus gate axe pada
 * tiga keadaan panel sesi × 2 tema × 2 locale.
 *
 * Fixture: paket dev `packs/base/seed/0002_dev_teller.sql` menyediakan vault cabang uji dan izin
 * untuk user dev. Party/produk/rekening dibuat lewat API setiap run supaya tidak menumpuk data dan
 * tidak bergantung pada urutan spec lain.
 *
 * Batas yang diuji: tanpa F-key (T-095); seluruh interaksi memakai Tab/Enter/fokus.
 */

requireDatabase();

// Port tetap dari playwright.config.ts (API e2e sengaja beda dari API dev).
const API = "http://127.0.0.1:8099";
const BRANCH = "e2e00000-0000-4000-8000-000000000001";
const MAKER = { username: "dev.maker", password: "rahasia-panjang-123" };
const CHECKER = { username: "dev.checker", password: "rahasia-panjang-123" };
const LOCALES = ["id", "en"] as const;
const THEMES = ["light", "dark"] as const;

type Text = {
  loginTitle: string;
  accountNo: string;
  load: string;
  sessionOpen: string;
  sessionClose: string;
  floatLabel: string;
  countedLabel: string;
  amountLabel: string;
  review: string;
  save: string;
  success: string;
  closed: string;
  even: string;
  openStatus: string;
};

const T: Record<"id" | "en", Text> = {
  id: {
    loginTitle: "Masuk",
    accountNo: "Nomor rekening",
    load: "Muat rekening",
    sessionOpen: "Buka sesi",
    sessionClose: "Tutup sesi",
    floatLabel: "Float awal (IDR)",
    countedLabel: "Kas dihitung (IDR)",
    amountLabel: "Nominal (IDR)",
    review: "Tinjau",
    save: "Simpan transaksi",
    success: "Transaksi tersimpan",
    closed: "Sesi kas ditutup",
    even: "Tidak ada selisih",
    openStatus: "Terbuka",
  },
  en: {
    loginTitle: "Sign in",
    accountNo: "Account number",
    load: "Load account",
    sessionOpen: "Open session",
    sessionClose: "Close session",
    floatLabel: "Opening float (IDR)",
    countedLabel: "Counted cash (IDR)",
    amountLabel: "Amount (IDR)",
    review: "Review",
    save: "Save transaction",
    success: "Transaction saved",
    closed: "Cash session closed",
    even: "No variance",
    openStatus: "Open",
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

type Fixture = { accountId: string; accountNo: string; cookie: string };

/**
 * Tutup sesi OPEN yang tertinggal dari run sebelumnya. Tanpa ini, run kedua tidak menemukan
 * tombol "Buka sesi" (partial unique: satu sesi OPEN per teller/cabang) dan gagal karena data,
 * bukan karena perilaku aplikasi. Counted = float awal supaya vault tidak terkuras oleh run gagal.
 */
async function closeLeftoverSession(request: APIRequestContext, cookie: string): Promise<void> {
  const current = await request.get(
    `${API}/api/v1/teller/sessions/current?branchId=${BRANCH}`,
    { headers: { Cookie: cookie } },
  );
  if (current.status() !== 200) return;
  const session = (await current.json()) as { sessionId: string; openingFloat: string };
  const closed = await request.post(`${API}/api/v1/teller/sessions/${session.sessionId}/close`, {
    headers: { Cookie: cookie, "Idempotency-Key": `e2e-cleanup-${Date.now()}` },
    data: { countedCash: session.openingFloat },
  });
  expect([200, 409], `tutup sesi sisa: ${await closed.text()}`).toContain(closed.status());
}

/** Produk SAVINGS ACTIVE + party + rekening baru pada cabang uji, semuanya lewat API. */
async function createAccountFixture(request: APIRequestContext): Promise<Fixture> {
  const maker = await apiLogin(request, MAKER);
  const checker = await apiLogin(request, CHECKER);
  await closeLeftoverSession(request, maker);
  const suffix = `${Date.now()}`.slice(-9);
  const code = `E2E${suffix}`;
  const headers = { Cookie: maker, "Idempotency-Key": `e2e-${suffix}` };

  const product = await request.post(`${API}/api/v1/products`, {
    headers: { Cookie: maker },
    data: {
      code,
      name: `Tabungan E2E ${suffix}`,
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
    data: { kind: "PERSON", displayName: `Nasabah E2E ${suffix}`, branchId: BRANCH },
  });
  expect(party.status(), `buat party: ${await party.text()}`).toBe(201);
  const partyId = ((await party.json()) as { partyId: string }).partyId;

  const account = await request.post(`${API}/api/v1/deposit/accounts`, {
    headers: { Cookie: maker, "Idempotency-Key": `e2e-account-${suffix}` },
    data: { partyId, productCode: code, branchId: BRANCH },
  });
  expect(account.status(), `buka rekening: ${await account.text()}`).toBe(201);
  const body = (await account.json()) as { accountId: string; accountNo: string };
  return { accountId: body.accountId, accountNo: body.accountNo, cookie: maker };
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

async function login(page: Page, text: Text): Promise<void> {
  await page.goto("/login");
  await expect(page.getByRole("heading", { level: 1, name: text.loginTitle })).toBeVisible();
  await page.getByLabel(text === T.id ? "Nama pengguna" : "Username", { exact: true }).focus();
  await page.keyboard.type(MAKER.username);
  await page.keyboard.press("Tab");
  await page.keyboard.type(MAKER.password);
  await page.keyboard.press("Enter");
  await expect(page).toHaveURL(/\/app\/ledger$/);
}

/** Muat rekening lewat nomor; dipakai sebelum panel sesi bisa tampil (cabang dari rekening). */
async function loadAccount(page: Page, text: Text, accountNo: string): Promise<void> {
  await page.goto("/app/teller");
  await page.getByLabel(text.accountNo, { exact: true }).fill(accountNo);
  await page.getByRole("button", { name: text.load }).click();
  await expect(page.getByText(accountNo, { exact: true })).toBeVisible();
}

async function focusAndEnter(page: Page, name: string): Promise<void> {
  await page.getByRole("button", { name }).last().focus();
  await page.keyboard.press("Enter");
}

test.describe.serial("teller: sesi kas, setor, tutup", () => {
  test("alur keyboard-only: buka sesi → setor → tutup tanpa selisih", async ({
    page,
    request,
  }) => {
    test.setTimeout(180_000);
    const fixture = await createAccountFixture(request);
    const text = T.id;

    await prepare(page, "id", "light");
    await login(page, text);
    const paramsLoaded = page.waitForResponse(
      (response) =>
        response.url().endsWith("/api/v1/params") && response.request().method() === "GET",
    );
    await loadAccount(page, text, fixture.accountNo);
    await paramsLoaded;

    // Pintasan dari parameter (T-095), bukan konstanta UI: F5 tarik, F9 PB, F4 setor.
    await page.keyboard.press("F5");
    await expect(page.getByRole("radio", { name: "Tarik (keluar)" })).toBeChecked();
    await page.keyboard.press("F9");
    await expect(page.getByRole("radio", { name: "PB (antar rekening)" })).toBeChecked();
    await page.keyboard.press("F4");
    await expect(page.getByRole("radio", { name: "Setor (masuk)" })).toBeChecked();

    // Buka sesi (keyboard-only): tombol → float 1000 → Tinjau → Buka sesi.
    await page.getByRole("button", { name: text.sessionOpen }).first().focus();
    await page.keyboard.press("Enter");
    await page.getByLabel(text.floatLabel, { exact: true }).fill("1000");
    await focusAndEnter(page, text.review);
    await focusAndEnter(page, text.sessionOpen);
    // Status dirender sebagai `<dd>` dengan glif status (aria-hidden), jadi cocokkan substring
    // di dalam region sesi, bukan teks exact.
    await expect(
      page.getByRole("region", { name: /Sesi kas|Cash session/ }).getByText(text.openStatus),
    ).toBeVisible();

    // Setor 10 (arah default Setor).
    await page.getByLabel(text.amountLabel, { exact: true }).fill("10");
    await focusAndEnter(page, text.review);
    await focusAndEnter(page, text.save);
    await expect(page.getByRole("heading", { name: text.success })).toBeVisible();

    // Tutup: kas fisik = float 1000 + setoran 10 → selisih nol.
    await page.getByRole("button", { name: text.sessionClose }).first().focus();
    await page.keyboard.press("Enter");
    await page.getByLabel(text.countedLabel, { exact: true }).fill("1010");
    await focusAndEnter(page, text.review);
    await focusAndEnter(page, text.sessionClose);
    await expect(page.getByRole("heading", { name: text.closed })).toBeVisible();
    await expect(page.getByText(text.even).first()).toBeVisible();

    // Saldo akhir dipastikan lewat API, bukan teks UI (teks diformat locale).
    const account = await request.get(`${API}/api/v1/deposit/accounts/${fixture.accountId}`, {
      headers: { Cookie: fixture.cookie },
    });
    expect(account.status()).toBe(200);
    const body = (await account.json()) as { balance: string };
    expect(body.balance).toBe("10.00");
  });

  test("axe: panel sesi tanpa sesi, sesi terbuka, dan hasil tutup × 2 tema × 2 locale", async ({
    page,
    request,
  }) => {
    test.setTimeout(300_000);
    const fixture = await createAccountFixture(request);

    // Buka sesi sekali lewat UI (light/id), lalu tiap kombinasi hanya reload + muat rekening.
    await prepare(page, "id", "light");
    await login(page, T.id);
    await loadAccount(page, T.id, fixture.accountNo);
    const sessionPanel = page.getByRole("region", { name: "Sesi kas" });
    await sessionPanel.getByRole("button", { name: T.id.sessionOpen }).click();
    await page.getByLabel(T.id.floatLabel, { exact: true }).fill("1000");
    await sessionPanel.getByRole("button", { name: T.id.review }).click();
    await sessionPanel.getByRole("button", { name: T.id.sessionOpen }).click();
    await expect(sessionPanel.getByText(T.id.openStatus)).toBeVisible();

    for (const locale of LOCALES) {
      for (const theme of THEMES) {
        const text = T[locale];
        await prepare(page, locale, theme);
        await page.reload();
        await loadAccount(page, text, fixture.accountNo);
        await expect(
          page
            .getByRole("region", { name: /Sesi kas|Cash session/ })
            .getByRole("definition")
            .filter({ hasText: text.openStatus })
            .first(),
        ).toBeVisible();
        const results = await new AxeBuilder({ page }).analyze();
        const serious = results.violations.filter(
          (violation) => violation.impact === "serious" || violation.impact === "critical",
        );
        expect(serious, `${locale}/${theme} sesi terbuka: ${serious.map((v) => v.id).join(", ")}`)
          .toEqual([]);
      }
    }

    // Tutup sesi (kas = float, tanpa transaksi) → keadaan hasil tutup. Kembali ke id/light dulu:
    // loop di atas berakhir pada en/dark, sedangkan tombol dicari dengan teks id.
    await prepare(page, "id", "light");
    await page.reload();
    await loadAccount(page, T.id, fixture.accountNo);
    const closingPanel = page.getByRole("region", { name: "Sesi kas" });
    await closingPanel.getByRole("button", { name: T.id.sessionClose }).click();
    await page.getByLabel(T.id.countedLabel, { exact: true }).fill("1000");
    await closingPanel.getByRole("button", { name: T.id.review }).click();
    await closingPanel.getByRole("button", { name: T.id.sessionClose }).click();
    await expect(page.getByRole("heading", { name: T.id.closed })).toBeVisible();

    for (const locale of LOCALES) {
      for (const theme of THEMES) {
        const text = T[locale];
        await prepare(page, locale, theme);
        await page.reload();
        await loadAccount(page, text, fixture.accountNo);
        await expect(page.getByText(text.sessionOpen, { exact: false }).first()).toBeVisible();
        const results = await new AxeBuilder({ page }).analyze();
        const serious = results.violations.filter(
          (violation) => violation.impact === "serious" || violation.impact === "critical",
        );
        expect(serious, `${locale}/${theme} tanpa sesi: ${serious.map((v) => v.id).join(", ")}`)
          .toEqual([]);
      }
    }
  });
});
