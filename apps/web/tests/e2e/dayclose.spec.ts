import AxeBuilder from "@axe-core/playwright";

import { blockingViolations } from "./axe.js";
import { expect, test, type APIRequestContext, type Page } from "@playwright/test";
import { requireDatabase } from "./db.js";

/**
 * Gate a11y + keyboard untuk monitor penutupan buku (T-139c): axe di 2 tema × 2 locale dan
 * jalur keyboard untuk kontrol yang selalu ada (muat ulang, batas riwayat).
 *
 * Aksi penutupan sengaja **tidak** dijalankan di sini: menutup buku mengubah tanggal bisnis dan
 * akan merusak spec lain yang berjalan sesudahnya. Yang diuji adalah halaman monitor dan
 * kontrolnya; aksi `run|resume|pause|cancel` sudah diuji di API (`itapi_dayclose`).
 */

requireDatabase();

const API = "http://127.0.0.1:8099";
const CONSOLE = { username: "dev.console", password: "rahasia-panjang-123" };
const LOCALES = ["id", "en"] as const;
const THEMES = ["light", "dark"] as const;

type Locale = (typeof LOCALES)[number];

const T: Record<
  Locale,
  {
    title: string;
    reload: string;
    limit: string;
    statusHeading: string;
    businessDate: string;
    businessDateUnknown: string;
  }
> = {
  id: {
    title: "Monitor penutupan buku",
    reload: "Muat ulang",
    limit: "Jumlah baris",
    statusHeading: "Status tanggal buku",
    businessDate: "Tanggal bisnis",
    businessDateUnknown: "belum tersedia",
  },
  en: {
    title: "Day-close monitor",
    reload: "Reload",
    limit: "Rows",
    statusHeading: "Business date status",
    businessDate: "Business date",
    businessDateUnknown: "unavailable",
  },
};

async function apiLogin(request: APIRequestContext): Promise<string> {
  const response = await request.post(`${API}/api/v1/auth/login`, { data: CONSOLE });
  expect(response.status(), "login dev.console").toBe(200);
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

async function prepare(page: Page, locale: Locale, theme: string): Promise<void> {
  await page.addInitScript(
    (init: { locale: string; theme: string }) => {
      localStorage.setItem("PARAGLIDE_LOCALE", init.locale);
      localStorage.setItem("kran-theme", init.theme);
    },
    { locale, theme },
  );
}

for (const locale of LOCALES) {
  for (const theme of THEMES) {
    test(`axe: /app/dayclose ${locale}/${theme}`, async ({ page, request }) => {
      const session = await apiLogin(request);
      await prepare(page, locale, theme);
      await browserLogin(page, session);

      await page.goto("/app/dayclose");
      await expect(page.getByRole("heading", { level: 1, name: T[locale].title })).toBeVisible();
      // Indikator shell memakai nilai dari API, bukan placeholder (spec §14.3). Locator dibatasi
      // ke header: teks "Business date" juga muncul di badan layar.
      const indicator = page.locator(".kran-business-date");
      await expect(indicator).toBeVisible();
      await expect(indicator).toContainText(T[locale].businessDate);
      // Indikator harus mencerminkan jawaban API, bukan teks tetap: dev.console memegang izin
      // baca penutupan buku, jadi bila institusi sudah punya baris tanggal buku nilainya tampil;
      // bila API menjawab null, shell mengatakannya apa adanya.
      const statusResponse = await request.get(`${API}/api/v1/dayclose/status`, {
        headers: { cookie: session },
      });
      const statusBody = (await statusResponse.json()) as {
        businessDate?: { date?: string } | null;
      };
      if (statusBody.businessDate?.date) {
        await expect(indicator).not.toContainText(T[locale].businessDateUnknown);
        await expect(indicator).toContainText(String(statusBody.businessDate.date.slice(0, 4)));
      } else {
        await expect(indicator).toContainText(T[locale].businessDateUnknown);
      }
      await expect(
        page.getByRole("heading", { level: 2, name: T[locale].statusHeading }),
      ).toBeVisible();

      const results = await new AxeBuilder({ page }).analyze();
      const blocking = blockingViolations(results.violations);
      expect(
        blocking,
        `/app/dayclose ${locale}/${theme}: ${blocking.map((violation) => violation.id).join(", ")}`,
      ).toEqual([]);
    });
  }
}

test("keyboard: muat ulang dan batas riwayat bisa dipakai tanpa tetikus", async ({
  page,
  request,
}) => {
  const session = await apiLogin(request);
  await prepare(page, "id", "light");
  await browserLogin(page, session);

  await page.goto("/app/dayclose");
  await expect(page.getByRole("heading", { level: 1, name: T.id.title })).toBeVisible();

  // Kontrol sengaja disabled selama pemuatan: tunggu sampai bisa dipakai, jangan menguji balapan
  // dengan fetch pertama (yang gagal ter-fokus saat disabled bukan cacat keyboard).
  const reload = page.getByRole("button", { name: T.id.reload, exact: true });
  await expect(reload).toBeEnabled();
  await reload.focus();
  await expect(reload).toBeFocused();
  await reload.press("Enter");

  // Muat ulang tidak boleh menghasilkan galat pada data seed.
  await expect(
    page.getByRole("heading", { level: 2, name: T.id.statusHeading }),
  ).toBeVisible();
  await expect(page.getByRole("alert")).toHaveCount(0);

  // Kontrol riwayat harus tercapai dengan Tab dari tombol muat ulang: itu yang membuat halaman
  // bisa dipakai tanpa tetikus. Perilaku panah di dalam `<select>` native (membuka popup) tidak
  // diuji di sini — Chromium headless tidak merender popup itu, sehingga hasilnya mengukur
  // browser, bukan aplikasi. Reaksi aplikasi terhadap perubahan nilainya diuji terpisah di bawah.
  const limit = page.getByLabel(T.id.limit, { exact: true });
  await expect(limit).toBeEnabled();
  let reached = false;
  for (let i = 0; i < 15; i += 1) {
    await page.keyboard.press("Tab");
    if (await limit.evaluate((element) => element === document.activeElement)) {
      reached = true;
      break;
    }
  }
  expect(reached, "select batas riwayat tercapai dengan Tab").toBe(true);

  await limit.selectOption("50");
  await expect(limit).toHaveValue("50");
  await expect(page.getByRole("alert")).toHaveCount(0);
});

test("keyboard: klik scrim tidak melepas trap, Escape menutup dan fokus kembali ke baris pemicu", async ({
  page,
  request,
}) => {
  const session = await apiLogin(request);
  await prepare(page, "id", "light");
  await browserLogin(page, session);

  // Riwayat disintesis lewat route: yang diuji di sini perilaku fokus drawer, bukan pembacaan DB.
  const run = {
    runId: "11111111-1111-4111-8111-111111111111",
    businessDate: "2026-11-10",
    scopeType: "INSTITUTION",
    levels: ["EOD"],
    state: "COMPLETED",
    startedAt: "2026-11-10T01:00:00Z",
    finishedAt: "2026-11-10T01:05:00Z",
    summaryHash: null,
    taskCounts: { ok: 1, failed: 0, skipped: 0, total: 1 },
  };
  await page.route("**/api/v1/dayclose/runs/*", (route) =>
    route.fulfill({ json: { ...run, tasks: [] } }),
  );
  await page.route(/\/api\/v1\/dayclose\/runs(\?.*)?$/, (route) =>
    route.fulfill({ json: { runs: [run] } }),
  );

  await page.goto("/app/dayclose");
  await expect(page.getByRole("heading", { level: 1, name: T.id.title })).toBeVisible();

  const rowButton = page.getByRole("button", { name: /Lihat detail run/ }).first();
  await expect(rowButton).toBeVisible();
  await rowButton.focus();
  await rowButton.press("Enter");

  const drawer = page.getByRole("dialog");
  await expect(drawer).toBeVisible();
  await expect(page.locator(".kran-drawer__title")).toBeFocused();

  // Scrim bukan elemen fokus: klik di luar panel memindahkan fokus keluar drawer, dan handler
  // yang hanya menempel di panel akan mati di titik itu padahal `aria-modal` masih menyala.
  await page.locator(".kran-drawer-scrim").click({ position: { x: 40, y: 40 } });
  expect(
    await page.evaluate(() => document.activeElement?.closest(".kran-drawer") === null),
    "fokus keluar dari panel setelah klik scrim",
  ).toBe(true);

  await page.keyboard.press("Escape");
  await expect(drawer).toHaveCount(0);
  await expect(rowButton).toBeFocused();
});
