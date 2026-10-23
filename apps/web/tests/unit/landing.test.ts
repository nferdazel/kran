/**
 * Akses panel opsional halaman `/app` (parameter & audit). Fungsi murni supaya keputusan
 * "baca panel ini atau tidak" bisa diuji tanpa DOM/jaringan: pemakai tanpa `platform.param.read` /
 * `platform.audit.read` harus mendapat halaman terdegradasi, bukan galat 403 (spec §13).
 */
import { describe, expect, it } from "vitest";

import { AUDIT_READ, PARAM_READ, landingAccess } from "#lib/app/landing.js";

describe("landingAccess", () => {
  it("admin (kedua izin) membaca kedua panel", () => {
    expect(landingAccess([PARAM_READ, AUDIT_READ, "platform.param.submit"])).toEqual({
      params: true,
      audit: true,
      degraded: false,
    });
  });

  it("hanya izin parameter: baca parameter saja, tanpa degradasi", () => {
    expect(landingAccess([PARAM_READ])).toEqual({ params: true, audit: false, degraded: false });
  });

  it("hanya izin audit: baca audit saja, tanpa degradasi", () => {
    expect(landingAccess([AUDIT_READ])).toEqual({ params: false, audit: true, degraded: false });
  });

  it("teller (tanpa izin parameter/audit) jatuh ke halaman terdegradasi", () => {
    expect(
      landingAccess(["teller.transaction.post", "teller.session.read", "deposit.account.read"]),
    ).toEqual({ params: false, audit: false, degraded: true });
  });

  it("sesi kosong = terdegradasi (fail-closed)", () => {
    expect(landingAccess([])).toEqual({ params: false, audit: false, degraded: true });
  });
});
