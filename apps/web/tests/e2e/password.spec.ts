import AxeBuilder from "@axe-core/playwright";

import { blockingViolations } from "./axe.js";
import { requireDatabase } from "./db.js";
import { expect, test, type Locator, type Page } from "@playwright/test";

/**
 * Alur wajib-ganti kata sandi (T-027, O-031) di UI nyata.
 *
 * Admin pertama dibuat `kran-api --role=ctl bootstrap-admin` dengan kata sandi acak yang dicetak
 * sekali. Sebelum diganti, akun itu hanya boleh memakai `/auth/session`, `/auth/password`, dan
 * `/auth/logout` — rute ber-izin dijawab 403 `password_change_required`. Yang dibuktikan di sini:
 *
 *   1. sesi berkewajiban-ganti diarahkan ke `/app/password` (bukan disuguhi galat 403);
 *   2. `/app` tidak bisa dipakai selama kata sandi belum diganti;
 *   3. kata sandi lama salah dan kata sandi baru yang melanggar kebijakan masing-masing
 *      menghasilkan pesan yang berbeda — pengguna tahu bagian mana yang harus diperbaiki;
 *   4. setelah berhasil, sesi **yang sama** bisa langsung bekerja tanpa masuk ulang;
 *   5. halaman ini lolos axe pada 2 tema (ia hanya muncul sekali per instalasi, jadi paling mudah
 *      luput dari pemeriksaan).
 *
 * Dua hal supaya test ini tidak saling menginjak — pelajaran dari run CI pertama yang merah:
 *   - test axe memakai `dev.maker` dan membuka `/app/password` **langsung** (halaman itu boleh
 *     dibuka siapa pun yang bersesi; yang wajib-ganti hanya *dipaksa* ke sana). Jadi mereka tidak
 *     menyentuh user wajib-ganti sama sekali.
 *   - test alur memakai `dev.firstlogin` dan **mengubah** kata sandinya, jadi ia satu-satunya yang
 *     memakai user itu. `retries: 0` di config berarti tidak ada percobaan ulang yang menemukan
 *     kata sandi sudah berubah.
 *
 * Karena kata sandi `dev.firstlogin` berubah, test alur butuh seed segar: `./task e2e` (dan
 * `dbtools seed --dev`) menyetel ulang password + `must_change_password` user dev.
 */

requireDatabase();

const DEV_PASSWORD = "rahasia-panjang-123";
/** User seed dengan `must_change_password = true` — hanya dipakai test alur. */
const FIRST_LOGIN = { username: "dev.firstlogin", password: DEV_PASSWORD };
/** User biasa (tanpa kewajiban ganti) — dipakai test axe supaya tidak ada keadaan yang dibagi. */
const MAKER = { username: "dev.maker", password: DEV_PASSWORD };
const NEW_PASSWORD = "Kata-Sandi-E2E-Baru-Panjang";

/**
 * Tenggang untuk aksi yang menyentuh kata sandi: ganti kata sandi menjalankan **N+3** derivasi
 * PBKDF2 (verifikasi kata sandi lama + kata sandi baru terhadap hash berlaku + N hash riwayat +
 * hash kata sandi baru; N=5 terburuk → 8). `dev.firstlogin` di suite ini belum punya riwayat, jadi
 * di sini 3 derivasi. Sisa suite berjalan paralel di 4 worker terhadap DB yang diakses lewat tunnel
 * SSH, dan biner e2e dibangun **debug** (`./task build`) sehingga kriptonya ~20x lebih lambat
 * daripada produksi (release). Tenggang bawaan 5 detik pernah membuat test ini gagal secara palsu di
 * CI — biaya + anggarannya di `docs/tasks/T-060.md` (T-060/O-068).
 */
const PASSWORD_TIMEOUT = { timeout: 20_000 } as const;

/** Teks katalog (id) yang dijadikan penanda di spec — dibaca dari `packages/i18n/messages`. */
const TEXT = {
  loginTitle: "Masuk",
  appTitle: "Parameter & jejak audit",
  /** Tujuan "Lanjut bekerja" untuk akun ini: buku besar, layar pertama yang boleh dibuka (UI-13). */
  ledgerTitle: "Saldo buku besar",
  title: "Ganti kata sandi",
  username: "Nama pengguna",
  password: "Kata sandi",
  oldLabel: "Kata sandi saat ini",
  newLabel: "Kata sandi baru",
  submit: "Ganti kata sandi",
  notice: "Ganti kata sandi dulu sebelum bekerja.",
  errorOld: "Kata sandi saat ini tidak cocok.",
  errorPolicy: "Kata sandi baru belum memenuhi kebijakan.",
  success: "Kata sandi diganti. Sesi Anda yang lain sudah dicabut.",
  continue: "Lanjut bekerja",
  logout: "Keluar",
} as const;

const THEMES = ["light", "dark"] as const;

/** Locale dipaksa `id` supaya penanda teks di atas deterministik (bukan tebakan bahasa browser). */
async function prepare(page: Page, theme = "light"): Promise<void> {
  await page.addInitScript((themeChoice: string) => {
    localStorage.setItem("PARAGLIDE_LOCALE", "id");
    localStorage.setItem("kran-theme", themeChoice);
  }, theme);
}

/** Label form dicari eksak: `getByLabel` longgar juga mengenai elemen ber-`aria-labelledby`. */
function field(page: Page, label: string): Locator {
  return page.getByLabel(label, { exact: true });
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

/** Masuk lewat keyboard-only, seperti alur lain: fokus, ketik, Tab, ketik, Enter. */
async function signIn(page: Page, user: { username: string; password: string }): Promise<void> {
  await page.goto("/login");
  await expect(page.getByRole("heading", { level: 1, name: TEXT.loginTitle })).toBeVisible();

  await field(page, TEXT.username).focus();
  await page.keyboard.type(user.username);
  await page.keyboard.press("Tab");
  await page.keyboard.type(user.password);
  await page.keyboard.press("Enter");

  await expect(page).not.toHaveURL(/\/login$/, PASSWORD_TIMEOUT);
}

for (const theme of THEMES) {
  test(`axe /app/password — tema ${theme}`, async ({ page }) => {
    await prepare(page, theme);
    await signIn(page, MAKER);
    await page.goto("/app/password");

    await expect(page.getByRole("heading", { level: 1, name: TEXT.title })).toBeVisible();
    await expect(page.locator("html")).toHaveAttribute("data-theme", theme);
    await expectNoSeriousViolations(page);
  });
}

test("wajib ganti: /app dialihkan sampai diganti, lalu sesi yang sama bisa bekerja", async ({
  page,
}) => {
  // Alur ini memuat dua verifikasi kata sandi + satu ganti dengan riwayat N=5 (≈8 derivasi
  // PBKDF2), sementara biner **debug** yang dipakai e2e ±20x lebih lambat dari release
  // (T-060/O-068: N=5 ≈ 13,6 s hanya untuk langkah ganti). Timeout global 30 s karena itu
  // terlalu ketat di mesin yang sibuk → `slow()` (3x) tanpa melonggarkan assertion apa pun.
  test.slow();

  await prepare(page);
  await signIn(page, FIRST_LOGIN);

  // Login user wajib-ganti mendarat di sini, bukan di halaman kerja.
  await expect(page).toHaveURL(/\/app\/password$/, PASSWORD_TIMEOUT);

  // Halaman kerja tidak disajikan sebagai galat: guard mengarahkan kembali ke sini. Pesannya
  // dicari lewat `filter` (bukan `getByRole("status")` polos): layout punya live region kosong.
  await page.goto("/app");
  await expect(page).toHaveURL(/\/app\/password$/);
  await expect(page.getByRole("status").filter({ hasText: TEXT.notice })).toBeVisible(
    PASSWORD_TIMEOUT,
  );

  // Kata sandi lama salah → pesan spesifik, bukan "permintaan tidak sah" yang tidak menolong.
  await field(page, TEXT.oldLabel).fill("kata-sandi-salah-sekali");
  await field(page, TEXT.newLabel).fill(NEW_PASSWORD);
  await page.getByRole("button", { name: TEXT.submit }).click();
  await expect(page.getByRole("alert")).toContainText(TEXT.errorOld, PASSWORD_TIMEOUT);

  // Kata sandi baru melanggar kebijakan → pesan yang berbeda lagi.
  await field(page, TEXT.oldLabel).fill(DEV_PASSWORD);
  await field(page, TEXT.newLabel).fill("pendek");
  await page.getByRole("button", { name: TEXT.submit }).click();
  await expect(page.getByRole("alert")).toContainText(TEXT.errorPolicy, PASSWORD_TIMEOUT);

  // Yang benar → berhasil; sesi ini tetap hidup, jadi tidak ada layar masuk kedua.
  await field(page, TEXT.oldLabel).fill(DEV_PASSWORD);
  await field(page, TEXT.newLabel).fill(NEW_PASSWORD);
  await page.getByRole("button", { name: TEXT.submit }).click();
  await expect(page.getByRole("status").filter({ hasText: TEXT.success })).toBeVisible(
    PASSWORD_TIMEOUT,
  );

  // Pemberitahuan wajib-ganti hilang setelah berhasil (tidak ada dua pesan yang bertentangan).
  await expect(page.getByRole("status").filter({ hasText: TEXT.notice })).toHaveCount(0);

  // T-133/UI-13: "Lanjut bekerja" menuju tautan nav pertama yang **boleh** dibuka akun ini. Untuk
  // `dev.firstlogin` (param_maker) itu buku besar — seed memberi izin baca jurnal; `/app` hanya
  // berisi parameter dan bukan tujuan yang benar untuk peran ini.
  await page.getByRole("link", { name: TEXT.continue }).click();
  await expect(page).toHaveURL(/\/app\/ledger$/);
  await expect(page.getByRole("heading", { level: 1, name: TEXT.ledgerTitle })).toBeVisible();

  // Kewajiban gantinya benar-benar hilang di server, bukan hanya di state halaman: muat ulang
  // halaman kerja, dan ia tetap boleh dipakai (tanpa pengalihan kembali).
  await page.reload();
  await expect(page).toHaveURL(/\/app\/ledger$/);
  await expect(page.getByRole("heading", { level: 1, name: TEXT.ledgerTitle })).toBeVisible();
});
