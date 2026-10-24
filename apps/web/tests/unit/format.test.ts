/**
 * Test unit format tanggal (T-132/UI-6).
 *
 * Bug aslinya halus: tanggal bisnis dibangun sebagai tengah malam UTC lalu diformat di zona
 * peramban, sehingga di zona negatif tanggal tampil **mundur sehari** pada slip dan laporan.
 * Zona mesin dipaksa negatif supaya perbedaan itu benar-benar terlihat, lalu dibuktikan bahwa
 * `formatDate` memakai kalender UTC.
 *
 * `process.env.TZ` disetel di tingkat modul (bukan `beforeAll`): Node membacanya saat
 * `Intl.DateTimeFormat` dibuat, dan `formatDate` membuat formatter baru tiap panggilan. Vitest
 * menjalankan tiap berkas di proses terpisah, jadi berkas lain tidak terpengaruh.
 */
import { describe, expect, it } from "vitest";

import { currentLocale } from "#lib/app/i18n.js";
import { formatDate } from "#lib/app/format.js";

process.env.TZ = "America/Los_Angeles";

function formatIn(isoDate: string, timeZone: string): string {
  const [year, month, day] = isoDate.split("-").map(Number);
  return new Intl.DateTimeFormat(currentLocale(), { dateStyle: "long", timeZone }).format(
    new Date(Date.UTC(year ?? 0, (month ?? 1) - 1, day ?? 1)),
  );
}

describe("formatDate", () => {
  it("memakai kalender UTC, bukan zona peramban", () => {
    for (const isoDate of ["2026-01-01", "2026-12-31", "2024-02-29"]) {
      // Bukti bahwa zona mesin memang menggeser: tanpa `timeZone: "UTC"` hasilnya berbeda.
      expect(formatIn(isoDate, "America/Los_Angeles") === formatIn(isoDate, "UTC")).toBe(false);
      expect(formatDate(isoDate)).toBe(formatIn(isoDate, "UTC"));
    }
  });
});
