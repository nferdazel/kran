import { describe, expect, it } from "vitest";

import { policyHint, type PasswordPolicy } from "#lib/app/password.js";

const POLICY: PasswordPolicy = { minLength: 12, minClasses: 3, historyCount: 5 };

describe("kebijakan kata sandi", () => {
  it("menyebut angka kebijakan yang berlaku, bukan angka di UI", () => {
    const text = policyHint(POLICY);
    expect(text).toContain("12");
    expect(text).toContain("3");
    expect(text).toContain("5");
  });

  it("tidak menyebut rahasia keamanan lain", () => {
    const text = policyHint(POLICY);
    expect(/pbkdf|lockout|iterasi/i.test(text)).toBe(false);
  });
});
