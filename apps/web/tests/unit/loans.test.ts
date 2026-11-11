/**
 * Turunan filter daftar pinjaman (T-292). Murni: dua nilai form masuk, satu boolean keluar.
 *
 * Dipakai layar untuk membedakan "belum ada pinjaman" (no-data) dari "filter tidak menemukan
 * apa pun" (no-match). Default keduanya kosong, jadi hasil kosong tanpa filter bukan no-match.
 */
import { describe, expect, it } from "vitest";

import { loanFilterActive } from "#lib/app/loans.js";

describe("loanFilterActive", () => {
  it("dua kontrol kosong = filter tidak aktif", () => {
    expect(loanFilterActive("", "")).toBe(false);
    expect(loanFilterActive("   ", "")).toBe(false);
  });

  it("anggota saja atau status saja sudah aktif", () => {
    expect(loanFilterActive("11111111-1111-4111-8111-111111111111", "")).toBe(true);
    expect(loanFilterActive("", "ACTIVE")).toBe(true);
  });

  it("spasi di sekitar anggota tidak dihitung sebagai isi", () => {
    // Status hanya dibandingkan dengan string kosong; spasi tetap dianggap pilihan.
    expect(loanFilterActive("  ", "  ")).toBe(true);
    expect(loanFilterActive(" 11111111-1111-4111-8111-111111111111 ", "")).toBe(true);
  });
});
