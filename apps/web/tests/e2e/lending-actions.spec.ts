import AxeBuilder from "@axe-core/playwright";

import { blockingViolations } from "./axe.js";
import { requireDatabase } from "./db.js";
import { expect, test, type APIRequestContext, type Page } from "@playwright/test";

/**
 * Aksi tulis pinjaman di layar detail (T-173): pencairan dengan pratinjau, batal yang tidak
 * mengirim, alur keyboard-only untuk pembayaran, dan gate axe pada panel aksi.
 *
 * Fixture dibuat lewat API setiap test, bukan dari seed (pola `loans.spec.ts`). Pencairan yang
 * diuji dari UI memakai akad `APPROVED` yang **belum** dicairkan; pembayaran memakai akad
 * `ACTIVE` hasil pencairan API.
 *
 * Akun: `dev.console` (`platform_admin`) memegang keempat izin tulis + `deposit.account.read`,
 * sedangkan `dev.loans` (`lending_maker`) tidak memegang `lending.loan.write_off` — dipakai untuk
 * membuktikan tombol hanya tampil bila izinnya ada. `dev.maker`/`dev.checker` membuat produk
 * simpanan + party + rekening, seperti spec pinjaman/teller.
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
const PRINCIPAL = "1200000.00";
const LOCALES = ["id", "en"] as const;
const THEMES = ["light", "dark"] as const;

type Locale = (typeof LOCALES)[number];

type Text = {
  detailTitle: string;
  actionsHeading: string;
  disburse: string;
  payment: string;
  account: string;
  amount: string;
  review: string;
  cancel: string;
  send: string;
  dialogPaymentTitle: string;
  disbursedNotice: string;
  paidNotice: string;
  activeStatus: string;
};

const T: Record<Locale, Text> = {
  id: {
    detailTitle: "Detail pinjaman",
    actionsHeading: "Aksi pinjaman",
    disburse: "Cairkan",
    payment: "Bayar angsuran",
    account: "Rekening sumber",
    amount: "Nominal",
    review: "Tinjau",
    cancel: "Batal",
    send: "Kirim",
    dialogPaymentTitle: "Konfirmasi pembayaran angsuran",
    disbursedNotice: "Pencairan tercatat",
    paidNotice: "Pembayaran tercatat",
    activeStatus: "Berjalan",
  },
  en: {
    detailTitle: "Loan detail",
    actionsHeading: "Loan actions",
    disburse: "Disburse",
    payment: "Pay instalment",
    account: "Source account",
    amount: "Amount",
    review: "Review",
    cancel: "Cancel",
    send: "Send",
    dialogPaymentTitle: "Confirm instalment payment",
    disbursedNotice: "Disbursement recorded",
    paidNotice: "Payment recorded",
    activeStatus: "Active",
  },
};

let fixtureSeq = 0;

function uniqueSuffix(): string {
  fixtureSeq += 1;
  return `${Date.now()}`.slice(-7) + `${fixtureSeq}`.padStart(2, "0");
}

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

type Fixture = { loanId: string; partyId: string; accountId: string };

/**
 * Akad + party + rekening lewat API. `disburse` menentukan status akhir: `true` → `ACTIVE`
 * (dipakai pembayaran), `false` → `APPROVED` yang belum pernah dicairkan (dipakai pencairan UI).
 */
async function createLoanFixture(
  request: APIRequestContext,
  options: { disburse: boolean },
): Promise<Fixture> {
  const suffix = uniqueSuffix();
  const code = `E2E${suffix}`;
  const maker = await apiLogin(request, MAKER);
  const checker = await apiLogin(request, CHECKER);
  const loans = await apiLogin(request, LOANS);
  const console = await apiLogin(request, CONSOLE);
  const headers = { Cookie: maker, "Idempotency-Key": `e2e-lending-actions-${suffix}` };

  const product = await request.post(`${API}/api/v1/products`, {
    headers: { Cookie: maker },
    data: {
      code,
      name: `Tabungan Aksi Pinjaman E2E ${suffix}`,
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
    data: { kind: "PERSON", displayName: `Peminjam Aksi E2E ${suffix}`, branchId: BRANCH },
  });
  expect(party.status(), `buat party: ${await party.text()}`).toBe(201);
  const partyId = ((await party.json()) as { partyId: string }).partyId;

  const account = await request.post(`${API}/api/v1/deposit/accounts`, {
    headers: { Cookie: maker, "Idempotency-Key": `e2e-lending-actions-account-${suffix}` },
    data: { partyId, productCode: code, branchId: BRANCH },
  });
  expect(account.status(), `buka rekening: ${await account.text()}`).toBe(201);
  const accountId = ((await account.json()) as { accountId: string }).accountId;

  const submitted = await request.post(`${API}/api/v1/lending/loans`, {
    headers: { Cookie: loans },
    data: { partyId, productVersionId: LOAN_VERSION, principal: PRINCIPAL },
  });
  expect(submitted.status(), `ajukan pinjaman: ${await submitted.text()}`).toBe(201);
  const loanId = ((await submitted.json()) as { loanId: string }).loanId;

  // Penyetuju harus orang lain (empat mata), jadi approve dilakukan `dev.console`.
  const approved = await request.post(`${API}/api/v1/lending/loans/${loanId}/approve`, {
    headers: { Cookie: console },
    data: {},
  });
  expect(approved.status(), `setujui pinjaman: ${await approved.text()}`).toBe(200);

  if (options.disburse) {
    const disbursed = await request.post(`${API}/api/v1/lending/loans/${loanId}/disburse`, {
      headers: {
        Cookie: loans,
        "Idempotency-Key": `e2e-lending-actions-disburse-${suffix}`,
      },
      data: { accountId },
    });
    expect(disbursed.status(), `cairkan pinjaman: ${await disbursed.text()}`).toBe(200);
  }

  return { loanId, partyId, accountId };
}

type LoanDetailBody = {
  status: string;
  disbursedOn: string | null;
  principalOutstanding: string | null;
  scheduleVersions: unknown[];
};

async function fetchLoan(
  request: APIRequestContext,
  cookie: string,
  loanId: string,
): Promise<LoanDetailBody> {
  const response = await request.get(`${API}/api/v1/lending/loans/${loanId}`, {
    headers: { Cookie: cookie },
  });
  expect(response.status(), `muat pinjaman: ${await response.text()}`).toBe(200);
  return (await response.json()) as LoanDetailBody;
}

/** Pilih aksi, isi rekening sumber, dan buka dialog pratinjau (bukan kirim). */
async function openPreview(
  page: Page,
  locale: Locale,
  fixture: Fixture,
  action: "disburse" | "payment",
): Promise<void> {
  await page.getByRole("button", { name: T[locale][action], exact: true }).click();
  await page.getByLabel(T[locale].account).selectOption(fixture.accountId);
  await page.getByRole("button", { name: T[locale].review, exact: true }).click();
  await expect(page.getByRole("dialog")).toBeVisible();
}

test.describe("pinjaman: aksi tulis", () => {
  test("pencairan: pratinjau menampilkan angka, batal tidak mengirim", async ({
    page,
    request,
  }) => {
    test.setTimeout(180_000);
    const fixture = await createLoanFixture(request, { disburse: false });
    const console = await apiLogin(request, CONSOLE);
    await browserLogin(page, console);
    await prepare(page, "id", "light");

    await page.goto(`/app/loans/${fixture.loanId}`);
    await expect(page.getByRole("heading", { level: 1, name: T.id.detailTitle })).toBeVisible();
    await expect(
      page.getByRole("heading", { level: 2, name: T.id.actionsHeading }),
    ).toBeVisible();

    let disburseRequests = 0;
    page.on("request", (req) => {
      if (req.method() === "POST" && req.url().endsWith("/disburse")) disburseRequests += 1;
    });

    await openPreview(page, "id", fixture, "disburse");

    // Pratinjau = angka yang akan dikirim, bukan hitungan di peramban.
    const dialog = page.getByRole("dialog");
    await expect(dialog).toContainText("1.200.000,00");
    await expect(
      dialog.getByRole("heading", { name: "Konfirmasi pencairan" }),
    ).toBeVisible();
    await expect(dialog).toContainText("Berjalan"); // konsekuensi status

    await page.getByRole("button", { name: T.id.cancel, exact: true }).click();
    await expect(dialog).toBeHidden();
    expect(disburseRequests, "batal tidak mengirim permintaan").toBe(0);

    const after = await fetchLoan(request, console, fixture.loanId);
    expect(after.status).toBe("APPROVED");
    expect(after.disbursedOn).toBeNull();
    expect(after.scheduleVersions).toHaveLength(0);
  });

  test("pencairan: kirim mengirim satu permintaan ber-Idempotency-Key lalu memuat ulang", async ({
    page,
    request,
  }) => {
    test.setTimeout(180_000);
    const fixture = await createLoanFixture(request, { disburse: false });
    const console = await apiLogin(request, CONSOLE);
    await browserLogin(page, console);
    await prepare(page, "id", "light");

    await page.goto(`/app/loans/${fixture.loanId}`);
    await expect(page.getByRole("heading", { level: 1, name: T.id.detailTitle })).toBeVisible();
    await openPreview(page, "id", fixture, "disburse");

    const keys: string[] = [];
    let disburseRequests = 0;
    page.on("request", (req) => {
      if (req.method() !== "POST" || !req.url().endsWith("/disburse")) return;
      disburseRequests += 1;
      keys.push(req.headers()["idempotency-key"] ?? "");
    });

    // Dua klik sinkron pada tombol yang sama: submit kedua harus berhenti di penjaga `busy`,
    // jadi hanya satu permintaan — bukan pencairan kedua.
    await page.getByRole("button", { name: T.id.send, exact: true }).evaluate((button) => {
      (button as HTMLButtonElement).click();
      (button as HTMLButtonElement).click();
    });

    await expect(page.getByText(T.id.disbursedNotice, { exact: false })).toBeVisible();
    await expect(page.getByText(T.id.activeStatus, { exact: true }).first()).toBeVisible();

    expect(disburseRequests, "satu permintaan pencairan").toBe(1);
    expect(keys[0], "Idempotency-Key terkirim").toMatch(
      /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i,
    );

    const after = await fetchLoan(request, console, fixture.loanId);
    expect(after.status).toBe("ACTIVE");
    expect(after.disbursedOn).not.toBeNull();
    expect(after.scheduleVersions, "satu versi jadwal, bukan dua").toHaveLength(1);

    // Status berubah → aksi pencairan hilang, pembayaran muncul (izin + keadaan).
    await expect(page.getByRole("button", { name: T.id.disburse, exact: true })).toHaveCount(0);
    await expect(page.getByRole("button", { name: T.id.payment, exact: true })).toBeVisible();
  });

  test("keyboard: bayar angsuran dari tombol sampai kirim tanpa tetikus", async ({
    page,
    request,
  }) => {
    test.setTimeout(180_000);
    const fixture = await createLoanFixture(request, { disburse: true });
    const console = await apiLogin(request, CONSOLE);
    await browserLogin(page, console);
    await prepare(page, "id", "light");

    await page.goto(`/app/loans/${fixture.loanId}`);
    await expect(page.getByRole("heading", { level: 1, name: T.id.detailTitle })).toBeVisible();

    const payButton = page.getByRole("button", { name: T.id.payment, exact: true });
    await payButton.focus();
    await expect(payButton).toBeFocused();
    await page.keyboard.press("Enter");

    // Popup `<select>` native tidak dirender Chromium headless (lihat catatan dayclose.spec);
    // nilainya diisi lewat API elemen, sisanya keyboard-only.
    await page.getByLabel(T.id.account).selectOption(fixture.accountId);
    const amount = page.getByLabel(T.id.amount);
    await amount.focus();
    await expect(amount).toBeFocused();
    await page.keyboard.type("100000");

    const review = page.getByRole("button", { name: T.id.review, exact: true });
    await review.focus();
    await expect(review).toBeFocused();
    await page.keyboard.press("Enter");

    const dialog = page.getByRole("dialog");
    await expect(dialog).toBeVisible();
    await expect(dialog).toContainText(T.id.dialogPaymentTitle);
    // Fokus awal ada di "Batal"; satu Tab mencapai "Kirim" di dalam dialog.
    await expect(page.getByRole("button", { name: T.id.cancel, exact: true })).toBeFocused();
    await page.keyboard.press("Tab");
    await expect(page.getByRole("button", { name: T.id.send, exact: true })).toBeFocused();
    await page.keyboard.press("Enter");

    await expect(page.getByText(T.id.paidNotice, { exact: false })).toBeVisible();

    const after = await fetchLoan(request, console, fixture.loanId);
    expect(after.status).toBe("ACTIVE");
    expect(after.principalOutstanding, "sisa pokok berkurang setelah pembayaran").not.toBe(
      PRINCIPAL,
    );
  });

  test("tombol hapus buku tidak tampil tanpa izinnya", async ({ page, request }) => {
    test.setTimeout(180_000);
    const fixture = await createLoanFixture(request, { disburse: true });
    await browserLogin(page, await apiLogin(request, LOANS));
    await prepare(page, "id", "light");

    await page.goto(`/app/loans/${fixture.loanId}`);
    await expect(page.getByRole("heading", { level: 1, name: T.id.detailTitle })).toBeVisible();
    await expect(
      page.getByRole("heading", { level: 2, name: T.id.actionsHeading }),
    ).toBeVisible();
    // `lending_maker` memegang bayar + restrukturisasi, tetapi bukan hapus buku.
    await expect(page.getByRole("button", { name: T.id.payment, exact: true })).toBeVisible();
    await expect(page.getByRole("button", { name: "Hapus buku", exact: true })).toHaveCount(0);
  });

  test("axe: detail pinjaman dengan panel aksi × 2 tema × 2 locale", async ({ page, request }) => {
    test.setTimeout(300_000);
    const fixture = await createLoanFixture(request, { disburse: true });
    const console = await apiLogin(request, CONSOLE);
    await browserLogin(page, console);

    for (const locale of LOCALES) {
      for (const theme of THEMES) {
        await prepare(page, locale, theme);
        await page.goto(`/app/loans/${fixture.loanId}`);
        await expect(
          page.getByRole("heading", { level: 1, name: T[locale].detailTitle }),
        ).toBeVisible();
        await expect(
          page.getByRole("heading", { level: 2, name: T[locale].actionsHeading }),
        ).toBeVisible();

        // Panel terbuka = kontrol formulir ikut dipindai, bukan hanya tombol aksi.
        await page.getByRole("button", { name: T[locale].payment, exact: true }).click();
        await page.getByLabel(T[locale].account).selectOption(fixture.accountId);
        await page.getByLabel(T[locale].amount).fill("100000");

        const panelResults = await new AxeBuilder({ page }).analyze();
        const panelBlocking = blockingViolations(panelResults.violations);
        expect(
          panelBlocking,
          `/app/loans/{loanId} panel ${locale}/${theme}: ${panelBlocking
            .map((violation) => violation.id)
            .join(", ")}`,
        ).toEqual([]);

        // Dialog pratinjau juga dipindai: ia memuat ringkasan uang dan tombol kirim.
        await page.getByRole("button", { name: T[locale].review, exact: true }).click();
        await expect(page.getByRole("dialog")).toBeVisible();
        const dialogResults = await new AxeBuilder({ page }).include("dialog").analyze();
        const dialogBlocking = blockingViolations(dialogResults.violations);
        expect(
          dialogBlocking,
          `/app/loans/{loanId} dialog ${locale}/${theme}: ${dialogBlocking
            .map((violation) => violation.id)
            .join(", ")}`,
        ).toEqual([]);

        await page.keyboard.press("Escape");
        await expect(page.getByRole("dialog")).toBeHidden();
      }
    }
  });
});
