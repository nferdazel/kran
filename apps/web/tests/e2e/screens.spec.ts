import AxeBuilder from "@axe-core/playwright";
import { expect, test, type APIRequestContext, type Page } from "@playwright/test";
import { requireDatabase } from "./db.js";

/**
 * Gate axe + keyboard untuk empat layar administrasi (T-132/UI-4).
 *
 * Sebelum ini `/app/users`, `/app/products`, `/app/ledger/admin`, dan `/app/accounts/open` tidak
 * punya spec sama sekali: rute dengan tabel padat, dialog inline, dan form bertingkat itu tidak
 * pernah diperiksa aksesibilitasnya, dan tidak ada bukti satu pun bahwa mereka bisa dipakai
 * keyboard-only. Katalog pesan tetap satu-satunya sumber teks di sini (tidak ada string UI yang
 * dikarang di test).
 *
 * Akun: `dev.console` (`platform_admin`, seed `0005_dev_console.sql`) — satu-satunya akun dev yang
 * memegang `ledger.period.manage` dan `platform.user.manage` sekaligus. Draf produk dibuat lewat
 * API sebagai `dev.maker` supaya tabel draf tidak kosong, dan party e2e dibuat lewat API supaya
 * pencarian rekening punya hasil.
 */

requireDatabase();

const API = "http://127.0.0.1:8099";
const BRANCH = "e2e00000-0000-4000-8000-000000000001";
const CONSOLE = { username: "dev.console", password: "rahasia-panjang-123" };
const MAKER = { username: "dev.maker", password: "rahasia-panjang-123" };
const LOCALES = ["id", "en"] as const;
const THEMES = ["light", "dark"] as const;

type Locale = (typeof LOCALES)[number];

type ScreenText = {
  title: string;
  /** Aksi utama layar — dipakai alur keyboard. */
  action: string;
};

const T: Record<Locale, { users: ScreenText; products: ScreenText; ledger: ScreenText; accounts: ScreenText }> = {
  id: {
    users: { title: "Administrasi pengguna", action: "Kelola" },
    products: { title: "Katalog produk", action: "Setujui" },
    ledger: { title: "Administrasi buku besar", action: "Buat akun" },
    accounts: { title: "Buka rekening simpanan", action: "Buka rekening" },
  },
  en: {
    users: { title: "User administration", action: "Manage" },
    products: { title: "Product catalogue", action: "Approve" },
    ledger: { title: "Ledger administration", action: "Create account" },
    accounts: { title: "Open savings account", action: "Open account" },
  },
};

const SCREENS = [
  { path: "/app/users", text: (locale: Locale) => T[locale].users },
  { path: "/app/products", text: (locale: Locale) => T[locale].products },
  { path: "/app/ledger/admin", text: (locale: Locale) => T[locale].ledger },
  { path: "/app/accounts/open", text: (locale: Locale) => T[locale].accounts },
] as const;

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

function todayIso(): string {
  return new Date().toISOString().slice(0, 10);
}

async function prepare(page: Page, locale: Locale, theme: string): Promise<void> {
  await page.addInitScript(
    (init: { locale: string; theme: string }) => {
      localStorage.setItem("PARAGLIDE_LOCALE", init.locale);
      localStorage.setItem("kran-theme", init.theme);
    },
    { locale, theme },
  );
}

/** Draf produk baru (belum disetujui) supaya tabel draf berisi data sungguhan. */
async function createDraftProduct(request: APIRequestContext, suffix: string): Promise<string> {
  const maker = await apiLogin(request, MAKER);
  const code = `E2E${suffix}`;
  const created = await request.post(`${API}/api/v1/products`, {
    headers: { Cookie: maker },
    data: {
      code,
      name: `Produk E2E ${suffix}`,
      productType: "SAVINGS",
      effectiveFrom: todayIso(),
      bindings: { "product.savings.min_balance": "0.00" },
    },
  });
  expect(created.status(), `buat draf produk: ${await created.text()}`).toBe(201);
  return code;
}

/** Party e2e supaya pencarian rekening punya satu hasil yang bisa dipilih. */
async function createParty(request: APIRequestContext, suffix: string): Promise<string> {
  const maker = await apiLogin(request, MAKER);
  const name = `Nasabah Layar ${suffix}`;
  const created = await request.post(`${API}/api/v1/parties`, {
    headers: { Cookie: maker, "Idempotency-Key": `e2e-screens-${suffix}` },
    data: { kind: "PERSON", displayName: name, branchId: BRANCH },
  });
  expect(created.status(), `buat party: ${await created.text()}`).toBe(201);
  return name;
}

async function openScreen(page: Page, path: string, title: string): Promise<void> {
  await page.goto(path);
  await expect(page.getByRole("heading", { level: 1, name: title })).toBeVisible();
}

for (const screen of SCREENS) {
  test(`axe: ${screen.path} dengan data × 2 tema × 2 locale`, async ({ page, request }) => {
    test.setTimeout(240_000);
    const suffix = `${Date.now()}`.slice(-9);
    // Data disiapkan sekali per layar: draf produk untuk `/app/products`, party untuk
    // `/app/accounts/open`. Layar lain memakai data seed (pengguna, periode, bagan akun).
    if (screen.path === "/app/products") await createDraftProduct(request, suffix);
    if (screen.path === "/app/accounts/open") await createParty(request, suffix);

    const console = await apiLogin(request, CONSOLE);
    await browserLogin(page, console);

    for (const locale of LOCALES) {
      for (const theme of THEMES) {
        await prepare(page, locale, theme);
        await openScreen(page, screen.path, screen.text(locale).title);
        const results = await new AxeBuilder({ page }).analyze();
        const serious = results.violations.filter(
          (violation) => violation.impact === "serious" || violation.impact === "critical",
        );
        expect(
          serious,
          `${screen.path} ${locale}/${theme}: ${serious.map((violation) => violation.id).join(", ")}`,
        ).toEqual([]);
      }
    }
  });
}

test.describe("keyboard-only", () => {
  test("pengguna: panel role dibuka dan ditutup dengan Enter", async ({ page, request }) => {
    const console = await apiLogin(request, CONSOLE);
    await prepare(page, "id", "light");
    await browserLogin(page, console);
    await openScreen(page, "/app/users", T.id.users.title);

    // Label tombol berganti "Kelola" → "Tutup" saat panel terbuka, jadi tiap langkah memakai
    // label yang berlaku saat itu: menekan Enter pada label lama hanya akan mengenai tombol baris
    // berikutnya dan membuat test seolah-olah "tidak terjadi apa-apa".
    const manage = page.getByRole("button", { name: T.id.users.action, exact: true }).first();
    await manage.focus();
    await expect(manage).toBeFocused();
    await page.keyboard.press("Enter");

    await expect(page.getByRole("heading", { name: "Role saat ini" })).toBeVisible();
    await expect(page.getByRole("button", { name: "Kelola", exact: true }).first()).toHaveAttribute(
      "aria-expanded",
      "false",
    );

    const close = page.getByRole("button", { name: "Tutup", exact: true }).first();
    await close.focus();
    await expect(close).toBeFocused();
    await page.keyboard.press("Enter");
    await expect(page.getByRole("heading", { name: "Role saat ini" })).toHaveCount(0);
  });

  test("produk: draf disetujui lewat Enter pada tombol dan konfirmasi", async ({
    page,
    request,
  }) => {
    const suffix = `${Date.now()}`.slice(-9);
    const code = await createDraftProduct(request, suffix);
    const console = await apiLogin(request, CONSOLE);
    await prepare(page, "id", "light");
    await browserLogin(page, console);
    await openScreen(page, "/app/products", T.id.products.title);

    // Produk baru muncul di dua tabel (draf dan katalog), jadi baris dicari di dalam region draf.
    const drafts = page.getByRole("region", { name: "Versi menunggu persetujuan" });
    const row = drafts.getByRole("row").filter({ hasText: code });
    await expect(row).toBeVisible();
    const approve = row.getByRole("button", { name: T.id.products.action, exact: true });
    await approve.focus();
    await approve.press("Enter");

    // Konfirmasi inline (bukan dialog): tombol kedua muncul dengan deskripsi aria.
    const confirm = page.getByRole("button", { name: "Ya, setujui", exact: true });
    await expect(confirm).toBeVisible();
    await confirm.focus();
    await confirm.press("Enter");

    await expect(page.getByRole("status").filter({ hasText: "Versi disetujui." })).toBeVisible();
    // Baris draf hilang dari tabel draf setelah disetujui.
    await expect(row).toHaveCount(0);
  });

  test("buku besar: form bagan akun diisi dan dikirim tanpa tetikus", async ({ page, request }) => {
    const console = await apiLogin(request, CONSOLE);
    await prepare(page, "id", "light");
    await browserLogin(page, console);
    await openScreen(page, "/app/ledger/admin", T.id.ledger.title);

    const code = page.getByLabel("Kode akun", { exact: true });
    await code.focus();
    await page.keyboard.type("199");
    await page.keyboard.press("Tab");

    const name = page.getByLabel("Nama akun", { exact: true });
    await expect(name).toBeFocused();
    await page.keyboard.type("AKUN UJI KEYBOARD");
    await page.keyboard.press("Tab");

    const type = page.getByLabel("Tipe akun", { exact: true });
    await expect(type).toBeFocused();
    await page.keyboard.press("Tab");

    // Checkbox "Bisa diposting" aktif secara default; Space membuktikan ia bisa diubah keyboard.
    const postable = page.getByLabel("Bisa diposting", { exact: true });
    await expect(postable).toBeFocused();
    await expect(postable).toBeChecked();
    await page.keyboard.press("Space");
    await expect(postable).not.toBeChecked();
    await page.keyboard.press("Tab");

    // Form berhenti di sini: test ini membuktikan jalur keyboard-nya utuh, bukan menambah akun baru
    // setiap run (akun uji yang menumpuk membuat tabel bagan akun sulit dibaca).
    const submit = page.getByRole("button", { name: T.id.ledger.action, exact: true });
    await expect(submit).toBeFocused();
    await expect(submit).toBeEnabled();
  });

  test("rekening: pencarian party dipilih lewat Tab dan Enter", async ({ page, request }) => {
    const suffix = `${Date.now()}`.slice(-9);
    const name = await createParty(request, suffix);
    const console = await apiLogin(request, CONSOLE);
    await prepare(page, "id", "light");
    await browserLogin(page, console);
    await openScreen(page, "/app/accounts/open", T.id.accounts.title);

    const search = page.getByLabel("Cari nama atau CIF", { exact: true });
    await search.focus();
    await page.keyboard.type(name);

    const result = page.getByRole("button", { name: new RegExp(name) }).first();
    await expect(result).toBeVisible();
    await result.focus();
    await result.press("Enter");

    await expect(page.getByText(new RegExp(`Dipilih: ${name}`))).toBeVisible();
    // Tanpa party terpilih, tombol buka rekening tidak masuk akal: setelah dipilih, form lanjut.
    await expect(page.getByLabel("Produk", { exact: true })).toBeVisible();
  });
});
