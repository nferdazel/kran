/**
 * Ambang gate axe untuk seluruh spec e2e.
 *
 * `moderate` ke atas memblokir (D-166/T-149). `minor` tidak: pelanggaran tingkat itu sebagian besar
 * kosmetik (mis. `region` pada iframe dekoratif) dan tidak pernah muncul di layar ini — bila muncul
 * dan memang salah, perbaiki di komponen, bukan dengan melonggarkan ambang.
 *
 * Satu definisi dipakai semua spec supaya ambangnya tidak bisa berbeda per layar tanpa sengaja.
 */
export const BLOCKING_IMPACTS = ["moderate", "serious", "critical"] as const;

export interface AxeViolation {
  id: string;
  impact?: string | null;
}

export function blockingViolations<T extends AxeViolation>(violations: T[]): T[] {
  return violations.filter(
    (violation) =>
      violation.impact !== null &&
      violation.impact !== undefined &&
      (BLOCKING_IMPACTS as readonly string[]).includes(violation.impact),
  );
}
