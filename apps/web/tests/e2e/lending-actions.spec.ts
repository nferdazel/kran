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
  restructure: string;
  writeOff: string;
  tenor: string;
  reason: string;
  dialogRestructureTitle: string;
  dialogWriteOffTitle: string;
  restructuredNotice: string;
  writtenOffNotice: string;
  insufficientBalance: string;
  recovery: string;
  recoveryPrincipal: string;
  recoveryInterest: string;
  recoveryPenalty: string;
  recoveryTotal: string;
  recoveryHint: string;
  recoveryReason: string;
  dialogRecoveryTitle: string;
  recoveredNotice: string;
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
    restructure: "Restrukturisasi",
    writeOff: "Hapus buku",
    tenor: "Tenor baru (bulan)",
    reason: "Alasan",
    dialogRestructureTitle: "Konfirmasi restrukturisasi",
    dialogWriteOffTitle: "Konfirmasi hapus buku",
    restructuredNotice: "Restrukturisasi tercatat",
    writtenOffNotice: "Hapus buku tercatat",
    insufficientBalance: "Saldo rekening sumber tidak cukup.",
    recovery: "Pemulihan",
    recoveryPrincipal: "Pokok",
    recoveryInterest: "Bunga",
    recoveryPenalty: "Denda",
    recoveryTotal: "Total pemulihan",
    recoveryHint: "Isi minimal satu komponen",
    recoveryReason: "Anggota membayar setelah hapus buku",
    dialogRecoveryTitle: "Konfirmasi pemulihan",
    recoveredNotice: "Pemulihan tercatat",
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
    restructure: "Restructure",
    writeOff: "Write off",
    tenor: "New tenor (months)",
    reason: "Reason",
    dialogRestructureTitle: "Confirm restructure",
    dialogWriteOffTitle: "Confirm write-off",
    restructuredNotice: "Restructure recorded",
    writtenOffNotice: "Write-off recorded",
    insufficientBalance: "The source account balance is not enough.",
    recovery: "Recovery",
    recoveryPrincipal: "Principal",
    recoveryInterest: "Interest",
    recoveryPenalty: "Penalty",
    recoveryTotal: "Recovery total",
    recoveryHint: "Fill at least one component",
    recoveryReason: "Member paid after write-off",
    dialogRecoveryTitle: "Confirm recovery",
    recoveredNotice: "Recovery recorded",
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

  test("restrukturisasi: tenor + alasan terkirim apa adanya dan jadwal jadi versi kedua", async ({
    page,
    request,
  }) => {
    test.setTimeout(180_000);
    const fixture = await createLoanFixture(request, { disburse: true });
    await browserLogin(page, await apiLogin(request, CONSOLE));
    await prepare(page, "id", "light");

    const bodies: unknown[] = [];
    const keys: string[] = [];
    page.on("request", (req) => {
      if (req.method() !== "POST" || !req.url().endsWith("/restructure")) return;
      bodies.push(req.postDataJSON());
      keys.push(req.headers()["idempotency-key"] ?? "");
    });

    await page.goto(`/app/loans/${fixture.loanId}`);
    await expect(page.getByRole("heading", { level: 1, name: T.id.detailTitle })).toBeVisible();
    await page.getByRole("button", { name: T.id.restructure, exact: true }).click();
    await page.getByLabel(T.id.tenor).fill("24");
    await page.getByLabel(T.id.reason).fill("Penurunan kemampuan bayar anggota");
    await page.getByRole("button", { name: T.id.review, exact: true }).click();

    const dialog = page.getByRole("dialog");
    await expect(dialog).toBeVisible();
    await expect(
      page.getByRole("heading", { level: 2, name: T.id.dialogRestructureTitle }),
    ).toBeVisible();

    await page.getByRole("button", { name: T.id.send, exact: true }).click();
    await expect(page.getByText(T.id.restructuredNotice, { exact: false })).toBeVisible();

    expect(bodies, "satu permintaan restrukturisasi").toHaveLength(1);
    expect(bodies[0]).toEqual({ tenorMonths: 24, reason: "Penurunan kemampuan bayar anggota" });
    expect(keys[0]).not.toBe("");

    const after = await fetchLoan(request, await apiLogin(request, CONSOLE), fixture.loanId);
    expect(after.scheduleVersions, "jadwal versi baru dibuat, yang lama diarsipkan").toHaveLength(2);
  });

  test("hapus buku: dialog meminta alasan, body hanya berisi reason", async ({ page, request }) => {
    test.setTimeout(180_000);
    const fixture = await createLoanFixture(request, { disburse: true });
    await browserLogin(page, await apiLogin(request, CONSOLE));
    await prepare(page, "id", "light");

    // Tanpa fixture LOSS + penyisihan, regrading tidak bisa dipaksa dari e2e. Yang diuji di sini
    // adalah jalur UI-nya: konfirmasi, body, dan penguncian izin. Server tetap diuji `itapi_lending`.
    const bodies: unknown[] = [];
    await page.route("**/api/v1/lending/loans/*/write-off", async (route) => {
      bodies.push(route.request().postDataJSON());
      await route.fulfill({
        status: 200,
        contentType: "application/json",
        body: JSON.stringify({
          loanId: fixture.loanId,
          status: "WRITTEN_OFF",
          principal: "0.00",
          interest: "0.00",
          penalty: "0.00",
          total: "0.00",
          allowanceApplied: "0.00",
          expense: "0.00",
          journalIds: ["00000000-0000-4000-8000-0000000000aa"],
          businessDate: todayIso(),
          reason: "Anggota pindah domisili",
        }),
      });
    });

    await page.goto(`/app/loans/${fixture.loanId}`);
    await expect(page.getByRole("heading", { level: 1, name: T.id.detailTitle })).toBeVisible();
    await page.getByRole("button", { name: T.id.writeOff, exact: true }).click();
    // Tanpa alasan, pratinjau tidak dibuka dan fokus pindah ke field yang salah.
    await page.getByRole("button", { name: T.id.review, exact: true }).click();
    await expect(page.getByRole("dialog")).toHaveCount(0);
    await expect(page.getByLabel(T.id.reason)).toBeFocused();
    await expect(page.getByLabel(T.id.reason)).toHaveAttribute("aria-invalid", "true");

    await page.getByLabel(T.id.reason).fill("Anggota pindah domisili");
    await page.getByRole("button", { name: T.id.review, exact: true }).click();
    await expect(
      page.getByRole("heading", { level: 2, name: T.id.dialogWriteOffTitle }),
    ).toBeVisible();

    const results = await new AxeBuilder({ page }).include("dialog").analyze();
    const blocking = blockingViolations(results.violations);
    expect(
      blocking,
      `dialog hapus buku: ${blocking.map((violation) => violation.id).join(", ")}`,
    ).toEqual([]);

    await page.getByRole("button", { name: T.id.send, exact: true }).click();
    await expect(page.getByText(T.id.writtenOffNotice, { exact: false })).toBeVisible();
    expect(bodies[0]).toEqual({ reason: "Anggota pindah domisili" });
  });

  test("kunci idempotensi: 5xx dipertahankan (replay), 409 membuat kunci baru", async ({
    page,
    request,
  }) => {
    test.setTimeout(180_000);
    const fixture = await createLoanFixture(request, { disburse: true });
    await browserLogin(page, await apiLogin(request, CONSOLE));
    await prepare(page, "id", "light");

    const keys: string[] = [];
    let reply: "500" | "409" = "500";
    await page.route("**/api/v1/lending/loans/*/payments", async (route) => {
      keys.push(route.request().headers()["idempotency-key"] ?? "");
      if (reply === "500") {
        await route.fulfill({
          status: 500,
          contentType: "application/problem+json",
          body: JSON.stringify({
            type: "about:blank",
            title: "galat",
            status: 500,
            code: "problem",
            i18nKey: "error_generic",
            traceId: "e2e-500",
          }),
        });
        return;
      }
      await route.fulfill({
        status: 409,
        contentType: "application/problem+json",
        body: JSON.stringify({
          type: "about:blank",
          title: "saldo tidak cukup",
          status: 409,
          code: "problem",
          i18nKey: "error_conflict",
          traceId: "e2e-409",
          params: { reason: "insufficient_balance" },
        }),
      });
    });

    await page.goto(`/app/loans/${fixture.loanId}`);
    await expect(page.getByRole("heading", { level: 1, name: T.id.detailTitle })).toBeVisible();
    await page.getByRole("button", { name: T.id.payment, exact: true }).click();
    await page.getByLabel(T.id.account).selectOption(fixture.accountId);
    await page.getByLabel(T.id.amount).fill("100000");
    await page.getByRole("button", { name: T.id.review, exact: true }).click();
    await page.getByRole("button", { name: T.id.send, exact: true }).click();

    // Hasil belum pasti: dialog tetap terbuka, "Kirim" berikutnya adalah replay kunci yang sama.
    await expect(page.getByRole("dialog")).toBeVisible();
    await page.getByRole("button", { name: T.id.send, exact: true }).click();
    await expect.poll(() => keys.length).toBe(2);
    expect(keys[0]).not.toBe("");
    expect(keys[1], "5xx tidak membuang kunci").toBe(keys[0]);

    // Tunggu respons pertama selesai diproses (`busy` turun), baru boleh menutup dengan Esc:
    // Esc saat permintaan berjalan sengaja diabaikan supaya kunci replay tidak hilang.
    await expect(page.getByRole("button", { name: T.id.send, exact: true })).toBeEnabled();

    // Esc saat tidak mengirim boleh menutup; dibuka lagi dengan isian sama = masih replay.
    await page.keyboard.press("Escape");
    await expect(page.getByRole("dialog")).toBeHidden();
    await page.getByRole("button", { name: T.id.review, exact: true }).click();
    await page.getByRole("button", { name: T.id.send, exact: true }).click();
    await expect.poll(() => keys.length).toBe(3);
    expect(keys[2], "kunci replay bertahan setelah dialog ditutup").toBe(keys[0]);

    // 409 = penolakan final: pesan menyebut sebabnya, lalu kunci dibuang.
    reply = "409";
    await expect(page.getByRole("button", { name: T.id.send, exact: true })).toBeEnabled();
    await page.getByRole("button", { name: T.id.send, exact: true }).click();
    await expect(page.getByText(T.id.insufficientBalance)).toBeVisible();
    await expect.poll(() => keys.length).toBe(4);
    expect(keys[3], "409 tetap memakai kunci kiriman itu").toBe(keys[0]);

    // Kiriman berikutnya dari dialog yang sama adalah permintaan baru (kunci baru).
    await expect(page.getByRole("button", { name: T.id.send, exact: true })).toBeEnabled();
    await page.getByRole("button", { name: T.id.send, exact: true }).click();
    await expect.poll(() => keys.length).toBe(5);
    expect(keys[4], "409 membuang kunci replay").not.toBe(keys[0]);
  });

  test("Esc saat kirim berjalan tidak menutup dialog; kunci bertahan per isian", async ({
    page,
    request,
  }) => {
    test.setTimeout(180_000);
    const fixture = await createLoanFixture(request, { disburse: true });
    await browserLogin(page, await apiLogin(request, CONSOLE));
    await prepare(page, "id", "light");

    // Route ditahan sampai test melepasnya: dipakai untuk membuktikan Esc diabaikan **selama**
    // permintaan berjalan, tanpa `waitForTimeout`.
    const keys: string[] = [];
    const holder: { release?: () => void } = {};
    const held = new Promise<void>((resolve) => {
      holder.release = resolve;
    });
    await page.route("**/api/v1/lending/loans/*/payments", async (route) => {
      keys.push(route.request().headers()["idempotency-key"] ?? "");
      await held;
      await route.fulfill({
        status: 500,
        contentType: "application/problem+json",
        body: JSON.stringify({
          type: "about:blank",
          title: "galat",
          status: 500,
          code: "problem",
          i18nKey: "error_generic",
          traceId: "e2e-held",
        }),
      });
    });

    await page.goto(`/app/loans/${fixture.loanId}`);
    await expect(page.getByRole("heading", { level: 1, name: T.id.detailTitle })).toBeVisible();
    await page.getByRole("button", { name: T.id.payment, exact: true }).click();
    await page.getByLabel(T.id.account).selectOption(fixture.accountId);
    await page.getByLabel(T.id.amount).fill("100000");
    await page.getByRole("button", { name: T.id.review, exact: true }).click();
    await page.getByRole("button", { name: T.id.send, exact: true }).click();

    await expect.poll(() => keys.length).toBe(1);
    await page.keyboard.press("Escape");
    // Permintaan belum selesai: dialog harus tetap terbuka, kalau tidak kunci replay hilang.
    await expect(page.getByRole("dialog")).toBeVisible();

    holder.release?.();
    await expect(page.getByRole("alert")).toBeVisible();
    await expect(page.getByRole("button", { name: T.id.send, exact: true })).toBeEnabled();

    // Isian berbeda = kunci baru; kembali ke isian lama = replay kunci pertama (peta per sidik).
    await page.keyboard.press("Escape");
    await expect(page.getByRole("dialog")).toBeHidden();
    await page.getByLabel(T.id.amount).fill("200000");
    await page.getByRole("button", { name: T.id.review, exact: true }).click();
    await page.getByRole("button", { name: T.id.send, exact: true }).click();
    await expect.poll(() => keys.length).toBe(2);
    expect(keys[1], "isian lain tidak memakai kunci isian pertama").not.toBe(keys[0]);

    await expect(page.getByRole("alert")).toBeVisible();
    await page.keyboard.press("Escape");
    await expect(page.getByRole("dialog")).toBeHidden();
    await page.getByLabel(T.id.amount).fill("100000");
    await page.getByRole("button", { name: T.id.review, exact: true }).click();
    await page.getByRole("button", { name: T.id.send, exact: true }).click();
    await expect.poll(() => keys.length).toBe(3);
    expect(keys[2], "kunci isian lama bertahan setelah isian lain dicoba").toBe(keys[0]);
  });

  test("pemulihan pasca hapus buku: tiga komponen, total dihitung, satu permintaan", async ({
    page,
    request,
  }) => {
    test.setTimeout(180_000);
    const fixture = await createLoanFixture(request, { disburse: true });
    await browserLogin(page, await apiLogin(request, CONSOLE));
    await prepare(page, "id", "light");

    // Pinjaman `WRITTEN_OFF` tidak bisa dibuat lewat API tanpa golongan LOSS + penyisihan, jadi
    // detail-nya distub. Yang diuji: UI mengirim tiga komponen apa adanya + kunci idempotensi.
    await page.route(/\/api\/v1\/lending\/loans\/[^/]+$/, async (route) => {
      if (route.request().method() !== "GET") {
        await route.fallback();
        return;
      }
      await route.fulfill({
        status: 200,
        contentType: "application/json",
        body: JSON.stringify({
          loanId: fixture.loanId,
          partyId: fixture.partyId,
          branchId: BRANCH,
          productVersionId: "00000000-0000-4000-8000-0000000000bb",
          status: "WRITTEN_OFF",
          principal: "1000000.00",
          disbursedOn: "2026-01-01",
          maturityOn: "2026-12-01",
          collectibility: "LOSS",
          principalOutstanding: "0.00",
          interestOverdue: "0.00",
          penaltyOutstanding: "0.00",
          scheduleVersions: [],
        }),
      });
    });

    const bodies: unknown[] = [];
    const keys: string[] = [];
    await page.route("**/api/v1/lending/loans/*/recovery", async (route) => {
      bodies.push(route.request().postDataJSON());
      keys.push(route.request().headers()["idempotency-key"] ?? "");
      await route.fulfill({
        status: 200,
        contentType: "application/json",
        body: JSON.stringify({
          loanId: fixture.loanId,
          status: "WRITTEN_OFF",
          recoveryId: "00000000-0000-4000-8000-0000000000cc",
          principal: "100000.00",
          interest: "25000.00",
          penalty: "0.00",
          total: "125000.00",
          journalIds: ["00000000-0000-4000-8000-0000000000dd"],
          businessDate: todayIso(),
          reason: T.id.recoveryReason,
        }),
      });
    });

    await page.goto(`/app/loans/${fixture.loanId}`);
    await expect(page.getByRole("heading", { level: 1, name: T.id.detailTitle })).toBeVisible();
    await page.getByRole("button", { name: T.id.recovery, exact: true }).click();
    await expect(page.getByText(T.id.recoveryHint, { exact: false })).toBeVisible();

    await page.getByLabel(T.id.account).selectOption(fixture.accountId);
    await page.getByLabel(T.id.recoveryPrincipal, { exact: true }).fill("100000");
    await page.getByLabel(T.id.recoveryInterest, { exact: true }).fill("25000");
    await page.getByLabel(T.id.reason).fill(T.id.recoveryReason);
    await page.getByRole("button", { name: T.id.review, exact: true }).click();

    const dialog = page.getByRole("dialog");
    await expect(dialog).toBeVisible();
    await expect(
      page.getByRole("heading", { level: 2, name: T.id.dialogRecoveryTitle }),
    ).toBeVisible();
    // Total dijumlahkan dari string (bukan float) dan ditampilkan sebelum dikirim.
    await expect(dialog.getByText(T.id.recoveryTotal)).toBeVisible();

    const results = await new AxeBuilder({ page }).include("dialog").analyze();
    const blocking = blockingViolations(results.violations);
    expect(
      blocking,
      `dialog pemulihan: ${blocking.map((violation) => violation.id).join(", ")}`,
    ).toEqual([]);

    await page.getByRole("button", { name: T.id.send, exact: true }).click();
    await expect(page.getByText(T.id.recoveredNotice, { exact: false })).toBeVisible();
    expect(bodies, "satu permintaan pemulihan").toHaveLength(1);
    expect(bodies[0]).toEqual({
      accountId: fixture.accountId,
      principal: "100000.00",
      interest: "25000.00",
      penalty: "0.00",
      reason: T.id.recoveryReason,
    });
    expect(keys[0]).not.toBe("");
  });

  test("pemulihan: tanpa komponen positif, pratinjau tidak dibuka", async ({ page, request }) => {
    test.setTimeout(180_000);
    const fixture = await createLoanFixture(request, { disburse: true });
    await browserLogin(page, await apiLogin(request, CONSOLE));
    await prepare(page, "id", "light");

    await page.route(/\/api\/v1\/lending\/loans\/[^/]+$/, async (route) => {
      if (route.request().method() !== "GET") {
        await route.fallback();
        return;
      }
      await route.fulfill({
        status: 200,
        contentType: "application/json",
        body: JSON.stringify({
          loanId: fixture.loanId,
          partyId: fixture.partyId,
          branchId: BRANCH,
          productVersionId: "00000000-0000-4000-8000-0000000000bb",
          status: "WRITTEN_OFF",
          principal: "1000000.00",
          disbursedOn: "2026-01-01",
          maturityOn: "2026-12-01",
          collectibility: "LOSS",
          principalOutstanding: "0.00",
          interestOverdue: "0.00",
          penaltyOutstanding: "0.00",
          scheduleVersions: [],
        }),
      });
    });

    await page.goto(`/app/loans/${fixture.loanId}`);
    await expect(page.getByRole("heading", { level: 1, name: T.id.detailTitle })).toBeVisible();
    await page.getByRole("button", { name: T.id.recovery, exact: true }).click();
    await page.getByLabel(T.id.account).selectOption(fixture.accountId);
    await page.getByLabel(T.id.reason).fill(T.id.recoveryReason);
    await page.getByRole("button", { name: T.id.review, exact: true }).click();
    await expect(page.getByRole("dialog")).toHaveCount(0);
    await expect(page.getByRole("alert")).toBeVisible();
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
