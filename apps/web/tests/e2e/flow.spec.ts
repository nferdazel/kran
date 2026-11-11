import AxeBuilder from "@axe-core/playwright";

import { blockingViolations } from "./axe.js";
import { requireDatabase } from "./db.js";
import { expect, test, type Locator, type Page } from "@playwright/test";

/**
 * Alur lengkap Fase 0 (spec §23) di UI nyata + gate a11y rute kerja (spec §17.2):
 * `/login` → maker mengajukan perubahan parameter → checker menyetujui → maker melihat nilai
 * baru **tanpa reload halaman** (itu bukti peristiwa `param.changed` sampai ke UI) dan jejak
 * audit berisi `param.submit` + `param.approve`.
 *
 * Interaksi alur memakai keyboard (fokus + `Enter`), sesuai kriteria backlog. Satu catatan jujur:
 * nilai pada `input[type=date]` ditulis dengan `fill()`, sebab mengetik tanggal bergantung format
 * locale browser dan tidak stabil lintas runner; semua fokus/aktivasi tetap lewat keyboard.
 *
 * Butuh DB + seed user dev (`./task e2e` menyiapkannya lewat `dbtools migrate` + `seed --dev`).
 * Tanpa `KRAN_DATABASE_URL` seluruh berkas ini dilewati; `a11y.spec.ts`/`keyboard.spec.ts` tetap
 * berjalan karena tidak menyentuh API.
 */

requireDatabase();

const MAKER = { username: "dev.maker", password: "rahasia-panjang-123" };
const CHECKER = { username: "dev.checker", password: "rahasia-panjang-123" };

/** Teks katalog (id) yang dijadikan penanda di spec — dibaca dari `packages/i18n/messages`. */
const TEXT = {
  loginTitle: "Masuk",
  ledgerTitle: "Saldo buku besar",
  appTitle: "Parameter & jejak audit",
  username: "Nama pengguna",
  password: "Kata sandi",
  submitHeading: "Ajukan perubahan",
  submitKey: "Parameter",
  submitValue: "Nilai baru",
  submitReason: "Alasan",
  submitDate: "Berlaku dari (opsional)",
  submit: "Ajukan perubahan",
  submitted: "Pengajuan tercatat dan menunggu persetujuan.",
  pendingHeading: "Menunggu persetujuan",
  activeHeading: "Nilai parameter aktif",
  auditHeading: "Jejak audit",
  approve: "Setujui",
  logout: "Keluar",
  reason: "e2e: alur Fase 0 (pengajuan uji)",
  loginError: "Tidak dapat masuk dengan akun ini.",
  loginLocked: "Akun terkunci sementara. Coba lagi nanti atau hubungi admin.",
  loginUnreachable: "Server KRAN tidak menjawab. Periksa jaringan kantor, lalu coba lagi.",
  loginMfaCodeLabel: "Kode autentikasi",
  loginMfaInvalid:
    "Kode itu tidak berlaku. Periksa jam perangkat Anda, lalu coba kode berikutnya.",
  loginMfaSubmit: "Verifikasi kode",
} as const;

const THEMES = ["light", "dark"] as const;

/** Locale dipaksa `id` supaya penanda teks di atas deterministik (bukan tebakan bahasa browser). */
async function prepare(page: Page, theme = "light"): Promise<void> {
  await page.addInitScript((themeChoice: string) => {
    localStorage.setItem("PARAGLIDE_LOCALE", "id");
    localStorage.setItem("kran-theme", themeChoice);
  }, theme);
}

function region(page: Page, name: string): Locator {
  // `exact`: nama landmark dicocokkan persis. Sejak T-133/UI-9 tabel bergulir di dalamnya juga
  // ber-`role="region"` dengan label "Tabel: …", dan pencocokan longgar Playwright (substring)
  // membuat dua elemen cocok untuk satu bagian.
  return page.getByRole("region", { name, exact: true });
}

/**
 * Label form dicari **eksak**: `getByLabel` juga cocok dengan elemen ber-`aria-labelledby`
 * (mis. seksi "Ajukan perubahan parameter"), sehingga pencarian longgar bisa mengenai seksi.
 */
function field(page: Page, label: string): Locator {
  return page.getByLabel(label, { exact: true });
}

async function login(page: Page, user: { username: string; password: string }): Promise<void> {
  await page.goto("/login");
  await expect(page.getByRole("heading", { level: 1, name: TEXT.loginTitle })).toBeVisible();

  // Keyboard-only: fokus field pertama, ketik, Tab, ketik, Enter (pengiriman implisit form).
  await field(page, TEXT.username).focus();
  await page.keyboard.type(user.username);
  await page.keyboard.press("Tab");
  await page.keyboard.type(user.password);
  await page.keyboard.press("Enter");

  // Landing mengikuti izin: maker mendarat di buku besar, checker (param_checker tanpa izin
  // ledger) di `/app`. Jangan mengunci rute ledger di helper yang dipakai keduanya; T-079
  // membuktikan landing maker di `ledger.spec.ts`.
  await expect(page).toHaveURL(/\/app(\/|$)/);
  await expect(page.getByRole("heading", { level: 1 })).toBeVisible();

  // Alur Fase 0 (parameter) tetap diuji di layarnya sendiri; pindah lewat rute nyata.
  await page.goto("/app/params");
  await expect(page.getByRole("heading", { level: 1, name: TEXT.appTitle })).toBeVisible();
}

/**
 * Baris tabel pertama (dari `rows`) yang sel `value`-nya persis `value`.
 * Sel ke-0 selalu kolom Nilai pada tabel parameter; pencocokan memakai sel itu, bukan teks
 * seluruh baris — supaya angka nilai tidak tertukar dengan tanggal atau id uuid.
 */
async function findRow(rows: Locator, value: string): Promise<Locator | null> {
  const count = await rows.count();
  for (let index = 0; index < count; index += 1) {
    const cell = (await rows.nth(index).locator("td").nth(0).innerText()).trim();
    if (cell === value) return rows.nth(index);
  }
  return null;
}

/**
 * Menunggu baris muncul, tetapi melaporkan galat UI yang terlihat (mis. 400/409 dari server)
 * sebagai alasan kegagalan — bukan sekadar timeout yang tidak informatif.
 */
async function waitForRow(
  page: Page,
  rows: Locator,
  value: string,
  what: string,
): Promise<Locator> {
  await expect
    .poll(
      async () => {
        const alerts = await page.getByRole("alert").allInnerTexts();
        if (alerts.length > 0) return `galat UI: ${alerts.join(" | ")}`;
        return (await findRow(rows, value)) === null ? `baris ${what} belum muncul` : "ok";
      },
      { timeout: 15_000, message: `${what}: baris parameter tidak muncul` },
    )
    .toBe("ok");

  const row = await findRow(rows, value);
  if (row === null) throw new Error(`${what}: baris hilang tepat setelah poll berhasil`);
  return row;
}

/**
 * Baris aktif pertama yang nilainya angka → sasaran uji, lalu arahkan form pengajuan ke baris itu.
 *
 * Daftar aktif juga memuat parameter **teks** (mis. `party.cif.format` yang bernilai pola), dan
 * urutan tampil tidak dijamin stabil saat parameter baru masuk. Jadi sasaran dipilih dari nilainya,
 * bukan dari baris/urutan pertama.
 */
async function pickTarget(page: Page): Promise<{ key: string; current: number }> {
  const rows = region(page, TEXT.activeHeading).locator("tbody tr");
  const count = await rows.count();
  if (count === 0) throw new Error("tidak ada nilai parameter aktif");

  for (let index = 0; index < count; index += 1) {
    const row = rows.nth(index);
    const raw = (await row.locator("td").nth(0).innerText()).trim();
    const current = Number(raw);
    if (!Number.isFinite(current)) continue;

    const key = (await row.locator("th").first().innerText()).trim();
    const select = field(page, TEXT.submitKey);
    await select.selectOption(key);
    await expect(select).toHaveValue(key);
    return { key, current };
  }

  throw new Error("tidak ada parameter aktif bernilai angka untuk diuji");
}

/**
 * Nilai uji berikutnya: osilasi ±1 dengan paritas.
 *
 * Menaikkan nilai terus-menerus akan menembus `maximum` schema setelah sekian kali dijalankan
 * (mis. `fiscal_year_start_month` maksimum 12) dan mengubah kebijakan dev secara permanen.
 * Dengan paritas, nilai selalu berada di antara dua angka berdekatan — tetap sah untuk rentang
 * apa pun yang memuat nilai awal pack — tetapi selalu **berbeda** dari nilai aktif sekarang,
 * sehingga perubahan nilainya bisa dibuktikan.
 */
function nextValue(current: number): number {
  return current % 2 === 0 ? current - 1 : current + 1;
}

function addDays(isoDate: string, days: number): string {
  const at = new Date(`${isoDate}T00:00:00Z`);
  at.setUTCDate(at.getUTCDate() + days);
  return at.toISOString().slice(0, 10);
}

/**
 * Tanggal efektif yang aman untuk (key) ini.
 *
 * PERANGKAP periode (migrasi 0004 `param_value_period_chk` + EXCLUDE `daterange(...,'[)')`):
 * saat menyetujui, nilai lama di-supersede dengan `effective_to = effective_from` nilai baru.
 * Bila tanggal baru <= tanggal lama, CHECK `effective_to > effective_from` dilanggar → 409
 * `period_conflict`. Jadi tanggal selalu **di atas** tanggal efektif terbesar yang sudah ada
 * untuk kunci itu (lihat juga `T-012 (git history)`).
 */
async function nextEffectiveFrom(page: Page, key: string): Promise<string> {
  const response = await page.request.get("/api/v1/params");
  expect(response.ok()).toBe(true);
  const body = (await response.json()) as {
    items: Array<{ key: string; effectiveFrom: string }>;
  };
  const dates = body.items
    .filter((row) => row.key === key)
    .map((row) => row.effectiveFrom)
    .sort();
  const latest = dates.at(-1);
  const today = new Date().toISOString().slice(0, 10);
  if (latest === undefined || latest < today) return today;
  return addDays(latest, 1);
}

async function expectNoSeriousViolations(page: Page): Promise<void> {
  const results = await new AxeBuilder({ page }).analyze();
  const blocking = blockingViolations(results.violations);
  expect(
    blocking.map((violation) => ({
      id: violation.id,
      impact: violation.impact,
      nodes: violation.nodes.map((node) => node.target.join(" ")),
    })),
  ).toEqual([]);
}

test("alur Fase 0: login → ajukan (maker) → setujui (checker) → audit + realtime tanpa reload", async ({
  browser,
}) => {
  const makerContext = await browser.newContext();
  const maker = await makerContext.newPage();
  await prepare(maker);
  await login(maker, MAKER);

  // Penanda "halaman ini belum pernah dimuat ulang": harus bertahan sampai akhir alur.
  await maker.evaluate(() => {
    (window as unknown as { __guard?: number }).__guard = 1;
  });

  // Daftar aktif harus terisi lebih dulu: pilihan parameter di form diisi dari daftar yang sama.
  await expect(region(maker, TEXT.activeHeading).locator("tbody tr").first()).toBeVisible();

  const target = await pickTarget(maker);
  const value = String(nextValue(target.current));
  const effectiveFrom = await nextEffectiveFrom(maker, target.key);

  // --- maker mengajukan perubahan (key sudah tersorot dari daftar aktif) ---
  await field(maker, TEXT.submitValue).focus();
  await maker.keyboard.type(value);
  await maker.keyboard.press("Tab");
  await maker.keyboard.type(TEXT.reason);
  await maker.keyboard.press("Tab");
  await field(maker, TEXT.submitDate).fill(effectiveFrom);
  await maker.keyboard.press("Enter");

  await expect(maker.getByText(TEXT.submitted, { exact: true })).toBeVisible();

  const pending = region(maker, TEXT.pendingHeading);
  await waitForRow(
    maker,
    pending.locator("tbody tr", { hasText: target.key }),
    value,
    "PENDING (pengajuan maker)",
  );

  // Jejak audit pengajuan: aksi + alasan yang diketik pengguna (bukan teks generik).
  const audit = region(maker, TEXT.auditHeading);
  // `.first()` karena audit log append-only (trigger `audit_log_immutable`): tiap run menambah
  // satu baris, sehingga DB dev yang dipakai berulang punya lebih dari satu baris dengan alasan
  // ini. Tanpa `.first()`, assertion ini hanya benar pada DB yang baru direset — yaitu kondisi
  // CI — dan gagal pada run kedua di mesin dev (D-054).
  await expect(audit.getByText(TEXT.reason, { exact: true }).first()).toBeVisible();
  await expect(audit.getByText("param.submit", { exact: true }).first()).toBeVisible();

  // --- checker (konteks kedua) menyetujui ---
  const checkerContext = await browser.newContext();
  const checker = await checkerContext.newPage();
  await prepare(checker);
  await login(checker, CHECKER);

  // Maker tidak punya izin approve: form pengajuan ada, tombol Setujui tidak.
  await expect(maker.getByRole("button", { name: TEXT.approve })).toHaveCount(0);
  await expect(checker.getByRole("button", { name: TEXT.submit })).toHaveCount(0);

  const checkerPending = region(checker, TEXT.pendingHeading);
  const rowToApprove = await waitForRow(
    checker,
    checkerPending.locator("tbody tr", { hasText: target.key }),
    value,
    "PENDING (tampak checker)",
  );
  await rowToApprove.getByRole("button", { name: TEXT.approve }).press("Enter");

  const checkerActive = region(checker, TEXT.activeHeading);
  const approvedRow = await waitForRow(
    checker,
    checkerActive.locator("tbody tr", { hasText: target.key }),
    value,
    "ACTIVE (setelah checker menyetujui)",
  );
  await expect(approvedRow.locator("td").nth(2)).toContainText("Aktif");

  // --- bukti realtime di sesi maker: nilai baru muncul tanpa aksi apa pun dari maker ---
  const makerActive = region(maker, TEXT.activeHeading);
  const realtimeRow = await waitForRow(
    maker,
    makerActive.locator("tbody tr", { hasText: target.key }),
    value,
    "ACTIVE di UI maker (peristiwa param.changed)",
  );
  await expect(realtimeRow.locator("td").nth(2)).toContainText("Aktif");
  await expect(audit.getByText("param.approve", { exact: true }).first()).toBeVisible();

  // Tidak ada reload: penanda dari awal alur masih ada.
  const guard = await maker.evaluate(() => (window as unknown as { __guard?: number }).__guard);
  expect(guard).toBe(1);

  // --- keluar ---
  await maker.getByRole("button", { name: TEXT.logout }).press("Enter");
  await expect(maker).toHaveURL(/\/login$/);
  await expect(maker.getByRole("heading", { level: 1, name: TEXT.loginTitle })).toBeVisible();

  await makerContext.close();
  await checkerContext.close();
});

test("kredensial salah: pesan generik, tidak ada sesi", async ({ page }) => {
  await prepare(page);
  await page.goto("/login");

  await field(page, TEXT.username).fill("dev.maker");
  await field(page, TEXT.password).fill(`salah-${Date.now()}`);
  await page.getByRole("button", { name: TEXT.loginTitle }).click();

  const alert = page.getByRole("alert");
  await expect(alert).toBeVisible();
  // Pesan tidak boleh membocorkan apakah akunnya ada (spec §13/§18.2).
  await expect(alert).not.toContainText("dev.maker");
  await expect(alert).toHaveText(TEXT.loginError);

  // T-241 acceptance 6: galat hidup di dalam bidang, fokus pindah ke kata sandi, nama pengguna
  // tetap terisi supaya salah ketik bisa diperbaiki tanpa mengetik ulang.
  await expect(page.locator(".kran-signin__plane [role='alert']")).toBeVisible();
  await expect(field(page, TEXT.password)).toBeFocused();
  await expect(field(page, TEXT.username)).toHaveValue("dev.maker");

  await page.goto("/app");
  await expect(page).toHaveURL(/\/login$/);
});

/**
 * Amplop problem yang benar-benar dikirim API (spec §13). 403 terkunci/inaktif dan MFA, serta 400
 * kode salah, baru mungkin datang **setelah** kata sandi diverifikasi; kontrak itu dibuktikan
 * `itapi_auth` dan `itapi_mfa`, jadi di sini jawabannya di-stub dan yang diuji tampilan serta fokus.
 */
function problemResponse(status: number, reason: string) {
  return {
    status,
    contentType: "application/problem+json",
    body: JSON.stringify({
      type: "about:blank",
      title: "stub",
      status,
      code: `stub_${reason}`,
      i18nKey: "error_forbidden",
      params: { reason },
      traceId: "00000000-0000-4000-8000-00000000c0de",
    }),
  };
}

async function openLogin(page: Page): Promise<void> {
  await prepare(page);
  await page.goto("/login");
  await expect(page.getByRole("heading", { level: 1, name: TEXT.loginTitle })).toBeVisible();
}

test("akun terkunci: pesan login_locked, fokus tidak berpindah", async ({ page }) => {
  await page.route("**/api/v1/auth/login", (route) =>
    route.fulfill(problemResponse(403, "locked")),
  );
  await openLogin(page);

  await field(page, TEXT.username).fill("dev.maker");
  await field(page, TEXT.password).fill(MAKER.password);
  const submit = page.getByRole("button", { name: TEXT.loginTitle });
  await submit.click();

  await expect(page.getByRole("alert")).toHaveText(TEXT.loginLocked);
  // 403 tidak menyisakan field yang bisa diperbaiki, jadi fokus tidak dipindah ke kata sandi.
  // Tombol submit dinonaktifkan selama permintaan, jadi fokus jatuh ke body — perilaku yang sama
  // pada semua form di repo ini, bukan efek perubahan T-241.
  await expect(field(page, TEXT.password)).not.toBeFocused();
  await expect(submit).toBeEnabled();
});

test("MFA: satu field kode di bidang yang sama, fokus pindah, judul tetap", async ({ page }) => {
  await page.route("**/api/v1/auth/login", (route) =>
    route.fulfill(problemResponse(403, "mfa_required")),
  );
  await openLogin(page);

  const plane = page.locator(".kran-signin__plane");
  const h1 = page.getByRole("heading", { level: 1 });
  const widthBefore = (await plane.boundingBox())?.width ?? 0;
  const titleBefore = await h1.textContent();

  await field(page, TEXT.username).fill(MAKER.username);
  await field(page, TEXT.password).fill(MAKER.password);
  await page.getByRole("button", { name: TEXT.loginTitle }).click();

  const codeField = field(page, TEXT.loginMfaCodeLabel);
  await expect(codeField).toBeVisible();
  await expect(codeField).toBeFocused();
  // Dua field lama hilang, bukan ditumpuk: bidang yang sama, satu isian.
  await expect(field(page, TEXT.password)).toHaveCount(0);
  await expect(field(page, TEXT.username)).toHaveCount(0);
  await expect(h1).toHaveText(titleBefore ?? TEXT.loginTitle);

  const widthAfter = (await plane.boundingBox())?.width ?? 0;
  expect(Math.abs(widthAfter - widthBefore)).toBeLessThan(4);
});

test("kode MFA salah: pesan mfa_invalid, nilai terpilih, fokus tetap", async ({ page }) => {
  await page.route("**/api/v1/auth/login", (route) =>
    route.fulfill(problemResponse(403, "mfa_required")),
  );
  await page.route("**/api/v1/auth/mfa/challenge", (route) =>
    route.fulfill(problemResponse(400, "mfa_code_invalid")),
  );
  await openLogin(page);

  await field(page, TEXT.username).fill(MAKER.username);
  await field(page, TEXT.password).fill(MAKER.password);
  await page.getByRole("button", { name: TEXT.loginTitle }).click();

  const codeField = field(page, TEXT.loginMfaCodeLabel);
  await codeField.fill("123456");
  await page.getByRole("button", { name: TEXT.loginMfaSubmit }).click();

  await expect(page.getByRole("alert")).toHaveText(TEXT.loginMfaInvalid);
  await expect(codeField).toBeFocused();

  // Nilai lama tetap terpilih: ketikan berikutnya menimpa, bukan menempel di belakangnya.
  const selection = await codeField.evaluate((element) => {
    const input = element as HTMLInputElement;
    return {
      value: input.value,
      selected: input.value.slice(input.selectionStart ?? 0, input.selectionEnd ?? 0),
    };
  });
  expect(selection).toEqual({ value: "123456", selected: "123456" });
});

test("server tidak menjawab: pesan unreachable, isian utuh, tombol aktif", async ({ page }) => {
  await page.route("**/api/v1/auth/login", (route) => route.abort());
  await openLogin(page);

  await field(page, TEXT.username).fill(MAKER.username);
  await field(page, TEXT.password).fill(MAKER.password);
  await page.getByRole("button", { name: TEXT.loginTitle }).click();

  await expect(page.getByRole("alert")).toHaveText(TEXT.loginUnreachable);
  await expect(field(page, TEXT.username)).toHaveValue(MAKER.username);
  await expect(field(page, TEXT.password)).toHaveValue(MAKER.password);
  const submit = page.getByRole("button", { name: TEXT.loginTitle });
  await expect(submit).toBeEnabled();
  // Tidak ada keadaan "sedang mencoba" yang tertinggal: label kembali ke aksi aslinya.
  await expect(submit).toHaveText(TEXT.loginTitle);
});

test("/app mengantar ke tujuan yang sama dengan pendaratan setelah masuk", async ({ page }) => {  await prepare(page);
  await page.goto("/login");
  await field(page, TEXT.username).focus();
  await page.keyboard.type(MAKER.username);
  await page.keyboard.press("Tab");
  await page.keyboard.type(MAKER.password);
  await page.keyboard.press("Enter");

  await expect(page).not.toHaveURL(/\/login$/);
  const landing = page.url();

  await page.goto("/app");
  await expect(page).toHaveURL(landing);
});

for (const theme of THEMES) {
  test(`axe /login — tema ${theme}`, async ({ page }) => {
    await prepare(page, theme);
    await page.goto("/login");
    await expect(page.getByRole("heading", { level: 1, name: TEXT.loginTitle })).toBeVisible();
    await expect(page.locator("html")).toHaveAttribute("data-theme", theme);
    await expectNoSeriousViolations(page);
  });

  test(`axe /app setelah masuk — tema ${theme}`, async ({ page }) => {
    await prepare(page, theme);
    await login(page, MAKER);
    await expect(page.locator("html")).toHaveAttribute("data-theme", theme);
    await expect(region(page, TEXT.activeHeading)).toBeVisible();
    await expectNoSeriousViolations(page);
  });
}
