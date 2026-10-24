/**
 * Test unit aturan 401 → `/login` (T-132/UI-5).
 *
 * Dipisah dari komponen: yang diuji hanya keputusan (status + rute), bukan pengalihan itu sendiri.
 */
import { describe, expect, it } from "vitest";

import { LOGIN_PATH, shouldRedirectToLogin } from "#lib/app/api.js";

describe("shouldRedirectToLogin", () => {
  it("401 di rute kerja mengalihkan ke halaman masuk", () => {
    expect(shouldRedirectToLogin(401, "/app/users")).toBe(true);
    expect(shouldRedirectToLogin(401, "/app/teller")).toBe(true);
    expect(shouldRedirectToLogin(401, "/")).toBe(true);
  });

  it("401 di halaman masuk tidak mengalihkan (kredensial salah = jawaban normal)", () => {
    expect(shouldRedirectToLogin(401, LOGIN_PATH)).toBe(false);
  });

  it("status lain bukan sesi berakhir", () => {
    for (const status of [400, 403, 409, 429, 500, 503]) {
      expect(shouldRedirectToLogin(status, "/app/users")).toBe(false);
    }
  });
});
