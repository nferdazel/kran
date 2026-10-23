/**
 * Akses panel opsional pada halaman kerja `/app` (parameter & audit).
 *
 * Halaman ini menggabungkan dua izin baca yang berbeda: `platform.param.read` dan
 * `platform.audit.read`. Pemakai bisa punya salah satunya saja, jadi panel dibaca per izin,
 * bukan diasumsikan sekaligus. Fungsi murni supaya keputusan ini bisa diuji tanpa DOM/jaringan.
 */

export const PARAM_READ = "platform.param.read";
export const AUDIT_READ = "platform.audit.read";

export type LandingAccess = {
  /** Boleh membaca daftar parameter. */
  readonly params: boolean;
  /** Boleh membaca jejak audit. */
  readonly audit: boolean;
  /** Tidak punya keduanya: halaman menampilkan satu penjelasan jujur, bukan panel kosong. */
  readonly degraded: boolean;
};

export function landingAccess(permissions: readonly string[]): LandingAccess {
  const params = permissions.includes(PARAM_READ);
  const audit = permissions.includes(AUDIT_READ);
  return { params, audit, degraded: !params && !audit };
}
