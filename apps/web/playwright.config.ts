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
    env: { ...inheritedEnv, KRAN_DATABASE_URL: dbURL },
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
  // Batas tunggu bawaan 10 s (dari 5 s) — bukan untuk menutupi perilaku yang salah, melainkan karena
  // lingkungan ini memang lambat: setiap login memverifikasi PBKDF2 600.000 iterasi (parameter dev
  // `platform.security.password_pbkdf2_iterations`), DB dev ada di server lain lewat tunnel SSH, dan
  // 4 worker berjalan serentak. Pada 5 s, login yang sepenuhnya normal pun bisa melewati batas dan
  // membuat CI merah sesekali. Assertion tidak dilonggarkan; hanya batas waktunya (T-031).
  expect: { timeout: 10_000 },
  fullyParallel: false,
  forbidOnly: true,
  retries: 0,
  reporter: [["list"]],
  use: {
    baseURL,
    trace: "off",
    screenshot: "off",
  },
  projects: [
    {
      name: "chromium",
      use: { ...devices["Desktop Chrome"] },
    },
  ],
  webServer: servers,
});
