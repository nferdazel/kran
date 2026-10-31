import { defineConfig, devices } from "@playwright/test";

/**
 * Konfigurasi Playwright (spec §17.2: axe-core di rute utama × 2 tema × 2 locale + skenario
 * keyboard-only).
 *
 * `webServer` menjalankan **binary lokal** langsung (`node_modules/.bin`), bukan lewat
 * `pnpm run`: di mesin ini registry npm privat tidak resolve sehingga pnpm akan mencoba
 * memasang ulang dependency sebelum menjalankan skrip. Binary lokal = deterministik, dan di CI
 * yang punya registry normal tetap bekerja setelah `pnpm install`.
 */
const PORT = 4173;
const baseURL = `http://127.0.0.1:${PORT}`;
// Port API e2e: sengaja beda dari 8080 (API dev) supaya dua proses bisa hidup berdampingan
// dan Playwright selalu menguji binary hasil `./task build`, bukan sisa proses lama.
const API_PORT = 8099;
const apiURL = `http://127.0.0.1:${API_PORT}`;
const dbURL = process.env.KRAN_DATABASE_URL ?? "";

type Server = {
  command: string;
  url: string;
  reuseExistingServer: boolean;
  timeout: number;
  env?: Record<string, string>;
  stdout?: "pipe" | "ignore";
  stderr?: "pipe" | "ignore";
};

/**
 * Lingkungan proses induk, diteruskan eksplisit ke tiap `webServer`.
 *
 * Playwright memakai `env` yang diberikan sebagai **pengganti** lingkungan proses, dan API Nim
 * butuh `DYLD_FALLBACK_LIBRARY_PATH` di mesin dev ini (libpq Homebrew bersifat keg-only) —
 * tanpa diteruskan, binary API gagal start dengan "could not load: libpq.dylib".
 */
const inheritedEnv = Object.fromEntries(
  Object.entries(process.env).filter((entry): entry is [string, string] => entry[1] !== undefined),
);

const servers: Server[] = [];

/**
 * API hanya dijalankan bila `KRAN_DATABASE_URL` ada (sumbernya `.local/dev.env`, di-export
 * `./task e2e`): alur login→maker-checker→realtime butuh DB + seed dev yang sudah dimigrasi.
 * Tanpa DB, spec alur menyatakan dirinya dilewati; spec a11y/keyboard tetap berjalan.
 */
if (dbURL !== "") {
  // Binary API memuat libpq lewat `dlopen`. Di mesin dev, libpq Homebrew bersifat keg-only dan
  // hanya ditemukan lewat `DYLD_FALLBACK_LIBRARY_PATH` dari `.local/dev.env`. Variabel `DYLD_*`
  // tidak selamat melewati proses perantara ber-hardened (dyld menghapusnya), jadi berkas itu
  // di-`source` langsung oleh perintah ini sebelum `exec` — bukan dikirim lewat `env` Playwright.
  const apiCommand = [
    "set -a;",
    "[ -f ../../.local/dev.env ] && . ../../.local/dev.env;",
    "set +a;",
    `exec ../../.build/bin/kran-api --role=api --port=${API_PORT} --address=127.0.0.1`,
  ].join(" ");

  servers.push({
    command: apiCommand,
    url: `${apiURL}/healthz`,
    env: {
      ...inheritedEnv,
      KRAN_DATABASE_URL: dbURL,
      // Seluruh suite e2e login dari 127.0.0.1 — satu IP untuk puluhan login per menit, karena tiap
      // spec memakai akun dev yang berbeda dan cookie tidak dibagi antar berkas. Pembatas login
      // (T-128) memang bekerja per IP, jadi tanpa penimpaan ini suite akan dijawab 429 dan gagal
      // karena kapasitas, bukan karena perilaku aplikasi. Pembatasnya sendiri diuji di
      // `tlogin_guard` dan `itapi_users` dengan nilai default; di sini yang diuji bukan pembatas.
      KRAN_LOGIN_ATTEMPTS_PER_MINUTE: "1000",
    },
    reuseExistingServer: false,
    timeout: 30_000,
    stdout: "pipe",
    stderr: "pipe",
  });
}

servers.push({
  command: `./node_modules/.bin/vite build && ./node_modules/.bin/vite preview --port ${PORT} --strictPort --host 127.0.0.1`,
  url: baseURL,
  // Selalu bangun ulang: kalau server lama dibiarkan (mis. sisa run yang terputus), test bisa
  // "hijau" melawan build lama. Build di sini hanya hitungan detik.
  env: { ...inheritedEnv, KRAN_API_TARGET: apiURL },
  reuseExistingServer: false,
  timeout: 180_000,
  stdout: "ignore",
  stderr: "pipe",
});

export default defineConfig({
  testDir: "./tests/e2e",
  timeout: 30_000,
  // Batas tingkat-run (T-044/T-063): tanpanya, runner/worker yang macet membuat run menunggu
  // 9–12 menit tanpa pesan yang menerangkan sebabnya. Run penuh terukur di mesin ini 25–33 detik
  // (Playwright 25,0 s), jadi 8 menit tidak memotong run sehat tetapi mengubah macet menjadi
  // kegagalan terbaca — bahkan bila runner 10x lebih lambat.
  globalTimeout: 8 * 60_000,
  // Batas tunggu bawaan 10 s (dari 5 s) — bukan untuk menutupi perilaku yang salah, melainkan karena
  // lingkungan ini memang lambat: setiap login memverifikasi PBKDF2 600.000 iterasi (parameter dev
  // `platform.security.password_pbkdf2_iterations`), DB dev ada di server lain lewat tunnel SSH, dan
  // 4 worker berjalan serentak. Pada 5 s, login yang sepenuhnya normal pun bisa melewati batas dan
  // membuat CI merah sesekali. Assertion tidak dilonggarkan; hanya batas waktunya (T-031).
  expect: { timeout: 10_000 },
  fullyParallel: false,
  // Test berbagi DB dev dan satu teller/branch (sesi kas unik); menjalankan berkas secara paralel
  // membuat print/teller saling membuka/menutup sesi. Serial = deterministik, tetap < 1 menit.
  workers: 1,
  forbidOnly: true,
  retries: 0,
  reporter: [["list"]],
  use: {
    baseURL,
    trace: "off",
    screenshot: "off",
    // T-044: tanpa batas ini setiap aksi/permintaan punya batas **tak terhingga** (`actionTimeout`
    // bawaan 0); aksi yang macet baru berhenti di `globalTimeout` 8 menit, dan pesannya tidak
    // menyebut aksi mana. 60 detik jauh di atas operasi sah di mesin ini (login PBKDF2 + tunnel),
    // tetapi mengubah macet menjadi kegagalan yang menyebut locator/URL-nya sendiri.
    actionTimeout: 60_000,
    navigationTimeout: 60_000,
  },
  projects: [
    {
      name: "chromium",
      use: { ...devices["Desktop Chrome"] },
      // Zoom 125% dijalankan sebagai project sendiri supaya viewport-nya tidak ikut mengubah
      // suite lain (lihat `zoom-125` di bawah).
      testIgnore: /zoom-125\.spec\.ts$/,
    },
    {
      // DESIGN §4/§12 menetapkan target **1366×768 pada zoom 100–125%**. Playwright tidak bisa
      // menyetel zoom peramban, jadi zoom diemulasi lewat viewport dalam **CSS px** hasil bagi:
      // 1366 / 1.25 ≈ 1093 dan 768 / 1.25 ≈ 614 (device pixel ratio tetap 1).
      name: "zoom-125",
      use: { ...devices["Desktop Chrome"], viewport: { width: 1093, height: 614 } },
      testMatch: /zoom-125\.spec\.ts$/,
    },
  ],
  webServer: servers,
});
