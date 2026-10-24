import AxeBuilder from "@axe-core/playwright";
import { expect, test, type APIRequestContext, type Page } from "@playwright/test";
import { requireDatabase } from "./db.js";

/**
 * Vault kas (T-121): alur nyata ajukan → setujui → tolak, keyboard-only, plus gate axe pada
 * layar dengan data × 2 tema × 2 locale.
 *
 * Fixture: `packs/base/seed/0001_dev_users.sql` (pasangan `dev.cashmaker` dan `dev.cashchecker`,
 * keduanya `cash_admin`, dua akun berbeda), `0002_dev_teller.sql` (vault cabang uji), dan
 * `0004_dev_branch.sql` (master cabang `002`). Pengajuan setiap run memakai nomor bukti unik,
 * sehingga data run sebelumnya tidak membuat pencarian baris ambigu.
 *
 * Batas yang diuji: konfirmasi persetujuan inline, penolakan dengan alasan, saldo dihitung dari
 * API (bukan teks UI), dan tidak ada selisih saldo saat pengajuan ditolak.
 */

requireDatabase();

const API = "http://127.0.0.1:8099";
const BRANCH = "e2e00000-0000-4000-8000-000000000001";
const MAKER = { username: "dev.cashmaker", password: "rahasia-panjang-123" };
const CHECKER = { username: "dev.cashchecker", password: "rahasia-panjang-123" };
const SOURCE_ACCOUNT = "102";
const LOCALES = ["id", "en"] as const;
const THEMES = ["light", "dark"] as const;

type Text = {
  title: string;
  branch: string;
  balance: string;
  amount: string;
  source: string;
  note: string;
  amountFormat: string;
  filter: string;
  cancel: string;
  submit: string;
  submitted: string;
  approve: string;
  approveConfirm: string;
  approved: string;
  reject: string;
  rejectReason: string;
  rejectConfirm: string;
  rejected: string;
};

const T: Record<"id" | "en", Text> = {
  id: {
    title: "Vault kas",
    branch: "Cabang",
    balance: "Saldo vault",
    amount: "Nominal (IDR)",
    source: "Akun sumber (kode COA)",
    note: "Bukti dan tujuan",
    amountFormat: "Nominal hanya boleh angka, maksimum satu pemisah desimal.",
    filter: "Status",
    cancel: "Batal",
    submit: "Ajukan top-up",
    submitted: "Pengajuan terkirim dan menunggu keputusan.",
    approve: "Setujui",
    approveConfirm: "Setujui sekarang",
    approved: "Top-up disetujui. Saldo vault diperbarui.",
    reject: "Tolak",
    rejectReason: "Alasan penolakan",
    rejectConfirm: "Tolak pengajuan",
    rejected: "Pengajuan ditolak.",
  },
  en: {
    title: "Cash vault",
    branch: "Branch",
    balance: "Vault balance",
    amount: "Amount (IDR)",
    source: "Source account (COA code)",
    note: "Evidence and purpose",
    amountFormat: "Amount may only contain digits and at most one decimal separator.",
    filter: "Status",
    cancel: "Cancel",
    submit: "Request top-up",
    submitted: "Request submitted and waiting for a decision.",
    approve: "Approve",
    approveConfirm: "Approve now",
    approved: "Top-up approved. The vault balance is updated.",
    reject: "Reject",
    rejectReason: "Rejection reason",
    rejectConfirm: "Reject request",
    rejected: "Request rejected.",
  },
};

type Record_ = {
  requestId: string;
  amount: string;
  note: string;
  status: string;
  journalId: string;
};

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

async function vaultBalance(request: APIRequestContext, cookie: string): Promise<string> {
  const reply = await request.get(`${API}/api/v1/teller/vault?branchId=${BRANCH}`, {
    headers: { Cookie: cookie },
  });
  expect(reply.status(), await reply.text()).toBe(200);
  return ((await reply.json()) as { balance: string }).balance;
}

async function topUps(
  request: APIRequestContext,
  cookie: string,
  status: string,
): Promise<Record_[]> {
  const reply = await request.get(
    `${API}/api/v1/teller/vault/topups?branchId=${BRANCH}&status=${status}&limit=100`,
    { headers: { Cookie: cookie } },
  );
  expect(reply.status(), await reply.text()).toBe(200);
  return ((await reply.json()) as { items: Record_[] }).items;
}

/** Nominal desimal 4 angka → bilangan bulat 1/10000 tanpa float (arithmetic uang). */
function minor(decimal: string): bigint {
  const [whole = "0", fraction = ""] = decimal.split(".");
  return BigInt(whole + fraction.padEnd(4, "0").slice(0, 4));
}

async function browserLogin(page: Page, cookie: string): Promise<void> {
  const [name = "", value = ""] = cookie.split("=");
  await page.context().clearCookies();
  await page.context().addCookies([
    { name, value, domain: "127.0.0.1", path: "/", httpOnly: true, sameSite: "Lax" },
  ]);
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

async function openVault(page: Page, text: Text): Promise<void> {
  const requestsLoaded = page.waitForResponse(
    (response) =>
      response.url().includes("/api/v1/teller/vault/topups") &&
      response.request().method() === "GET",
  );
  await page.goto("/app/vault");
  await expect(page.getByRole("heading", { level: 1, name: text.title })).toBeVisible();
  await page.getByLabel(text.branch, { exact: true }).selectOption(BRANCH);
  await requestsLoaded;
  await expect(page.getByRole("heading", { name: text.balance })).toBeVisible();
}

/** Isi form pengajuan dan kirim dengan keyboard (fokus + Enter), bukan klik tetikus. */
async function submitTopUp(page: Page, text: Text, amount: string, note: string): Promise<void> {
  await page.getByLabel(text.amount, { exact: true }).fill(amount);
  await page.getByLabel(text.source, { exact: true }).fill(SOURCE_ACCOUNT);
  await page.getByLabel(text.note, { exact: true }).fill(note);
  const button = page.getByRole("button", { name: text.submit, exact: true });
  await button.focus();
  await page.keyboard.press("Enter");
  await expect(page.getByText(text.submitted)).toBeVisible();
}

test.describe.serial("vault: pengajuan dan keputusan top-up", () => {
  test("pengaju mengajukan, penyetuju menyetujui lalu menolak", async ({ page, request }) => {
    test.setTimeout(180_000);
    const suffix = `${Date.now()}`;
    const text = T.id;

    const makerCookie = await apiLogin(request, MAKER);
    const checkerCookie = await apiLogin(request, CHECKER);
    const before = await vaultBalance(request, checkerCookie);

    await prepare(page, "id", "light");
    await browserLogin(page, makerCookie);
    await openVault(page, text);

    // 0. Validasi klien: nominal tidak sah tidak dikirim dan pesannya tampil di form.
    await page.getByLabel(text.source, { exact: true }).fill(SOURCE_ACCOUNT);
    await page.getByLabel(text.note, { exact: true }).fill(`[E2E] invalid e2e-${suffix} | uji`);
    await page.getByLabel(text.amount, { exact: true }).fill("abc");
    const invalidSubmit = page.getByRole("button", { name: text.submit, exact: true });
    await invalidSubmit.focus();
    await page.keyboard.press("Enter");
    await expect(page.getByRole("alert")).toHaveText(text.amountFormat);

    // 1. Pengajuan (maker).
    await submitTopUp(page, text, "50000", `[E2E] slip e2e-${suffix} | isi vault`);

    const pending = await topUps(request, checkerCookie, "PENDING");
    const submitted = pending.find((item) => item.note.includes(suffix));
    expect(submitted, "pengajuan baru ada di daftar PENDING").toBeDefined();
    expect(submitted?.amount).toBe("50000.00");

    // 2. Persetujuan (checker, akun berbeda).
    await browserLogin(page, checkerCookie);
    await openVault(page, text);
    const row = page.getByRole("row").filter({ hasText: `e2e-${suffix} | isi vault` });
    await expect(row).toBeVisible();
    await row.getByRole("button", { name: text.approve, exact: true }).focus();
    await page.keyboard.press("Enter");
    // Batal menutup konfirmasi tanpa memutuskan apa pun.
    const cancel = page.getByRole("button", { name: text.cancel, exact: true });
    await cancel.focus();
    await page.keyboard.press("Enter");
    await expect(page.getByRole("button", { name: text.approveConfirm, exact: true })).toHaveCount(0);

    await row.getByRole("button", { name: text.approve, exact: true }).focus();
    await page.keyboard.press("Enter");
    const confirm = page.getByRole("button", { name: text.approveConfirm, exact: true });
    await confirm.focus();
    await page.keyboard.press("Enter");
    await expect(page.getByText(text.approved)).toBeVisible();

    const afterApprove = await vaultBalance(request, checkerCookie);
    expect(minor(afterApprove)).toBe(minor(before) + minor("50000"));
    const approved = (await topUps(request, checkerCookie, "APPROVED")).find(
      (item) => item.requestId === submitted?.requestId,
    );
    expect(approved?.journalId ?? "", "persetujuan menulis jurnal GL").not.toBe("");

    // 3. Penolakan (maker mengajukan lagi, checker menolak dengan alasan).
    await browserLogin(page, makerCookie);
    await openVault(page, text);
    await submitTopUp(page, text, "1000", `[E2E] slip e2e-${suffix}-reject | uji tolak`);
    const pendingReject = (
      await topUps(request, checkerCookie, "PENDING")
    ).find((item) => item.note.includes(`${suffix}-reject`));
    expect(pendingReject, "pengajuan kedua ada di daftar PENDING").toBeDefined();

    await browserLogin(page, checkerCookie);
    await openVault(page, text);
    const rejectRow = page.getByRole("row").filter({ hasText: `${suffix}-reject | uji tolak` });
    await rejectRow.getByRole("button", { name: text.reject, exact: true }).focus();
    await page.keyboard.press("Enter");
    await page.getByLabel(text.rejectReason, { exact: true }).fill("bukti tidak cocok");
    const rejectConfirm = page.getByRole("button", { name: text.rejectConfirm, exact: true });
    await rejectConfirm.focus();
    await page.keyboard.press("Enter");
    await expect(page.getByText(text.rejected)).toBeVisible();

    const afterReject = await vaultBalance(request, checkerCookie);
    expect(minor(afterReject), "penolakan tidak mengubah saldo").toBe(minor(afterApprove));
    const rejected = (await topUps(request, checkerCookie, "REJECTED")).find(
      (item) => item.requestId === pendingReject?.requestId,
    );
    expect(rejected?.status).toBe("REJECTED");
    expect(rejected?.journalId ?? "").toBe("");
  });

  test("mobile 390px: tanpa overflow halaman, form dan tabel tetap terbaca", async ({
    page,
    request,
  }) => {
    const checkerCookie = await apiLogin(request, CHECKER);
    await prepare(page, "id", "light");
    await browserLogin(page, checkerCookie);
    await page.setViewportSize({ width: 390, height: 844 });
    await openVault(page, T.id);

    // Halaman tidak boleh melebar (tabel boleh menggulir di dalam wadahnya sendiri).
    const overflow = await page.evaluate(
      () => document.documentElement.scrollWidth - document.documentElement.clientWidth,
    );
    expect(overflow, "scrollWidth - clientWidth").toBeLessThanOrEqual(0);
    await expect(page.getByLabel(T.id.amount, { exact: true })).toBeVisible();

    // Riwayat (bukan hanya PENDING) supaya tabel benar-benar berisi pada viewport sempit.
    const filtered = page.waitForResponse(
      (response) =>
        response.url().includes("/api/v1/teller/vault/topups") &&
        response.request().method() === "GET",
    );
    await page.getByLabel(T.id.filter, { exact: true }).selectOption("");
    await filtered;
    await expect(page.getByRole("table")).toBeVisible();
  });

  test("axe: layar vault dengan data × 2 tema × 2 locale", async ({ page, request }) => {
    test.setTimeout(180_000);
    const checkerCookie = await apiLogin(request, CHECKER);
    await browserLogin(page, checkerCookie);

    for (const locale of LOCALES) {
      for (const theme of THEMES) {
        const text = T[locale];
        await prepare(page, locale, theme);
        await openVault(page, text);
        const results = await new AxeBuilder({ page }).analyze();
        const serious = results.violations.filter(
          (violation) => violation.impact === "serious" || violation.impact === "critical",
        );
        expect(serious, `${locale}/${theme} vault: ${serious.map((v) => v.id).join(", ")}`).toEqual(
          [],
        );
      }
    }
  });
});
