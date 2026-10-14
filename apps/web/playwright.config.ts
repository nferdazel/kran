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

export default defineConfig({
  testDir: "./tests/e2e",
  timeout: 30_000,
  expect: { timeout: 5_000 },
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
  webServer: {
    command: `./node_modules/.bin/vite build && ./node_modules/.bin/vite preview --port ${PORT} --strictPort --host 127.0.0.1`,
    url: baseURL,
    // Selalu bangun ulang: kalau server lama dibiarkan (mis. sisa run yang terputus), test bisa
    // "hijau" melawan build lama. Build di sini hanya hitungan detik.
    reuseExistingServer: false,
    timeout: 180_000,
    stdout: "ignore",
    stderr: "pipe",
  },
});
