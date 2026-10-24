import { test } from "@playwright/test";

const hasDatabase = Boolean(process.env.KRAN_DATABASE_URL);

/**
 * Gerbang database untuk spec e2e (T-126).
 *
 * Di mesin developer tanpa tunnel, spec yang butuh API memang dilewati. Di CI **tidak boleh**:
 * skip diam-diam membuat job hijau tanpa menguji apa pun, dan itu persis kegagalan yang ditutup
 * audit 24 Okt 2026. Karena itu CI tanpa `KRAN_DATABASE_URL` = gagal, bukan skip.
 */
export function requireDatabase(): void {
  if (!hasDatabase && process.env.CI) {
    throw new Error(
      "KRAN_DATABASE_URL kosong di CI — spec e2e ini tidak boleh di-skip diam-diam (T-126)",
    );
  }
  test.skip(!hasDatabase, "KRAN_DATABASE_URL kosong — API e2e tidak dijalankan");
}
