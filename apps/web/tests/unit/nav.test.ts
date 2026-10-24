/**
 * Penyaringan navigasi per izin (spec §13). Logika murni (tanpa DOM, tanpa jaringan); pemakaian di
 * menu dan palette diuji e2e. Dijalankan dengan binary vitest milik `packages/ui`:
 *   cd apps/web && node ../../packages/ui/node_modules/vitest/vitest.mjs run tests/unit
 */
import { describe, expect, it } from "vitest";

import { appNavLinks, sessionPermissions, visibleNavLinks, type NavLink } from "#lib/app/nav.js";

function hrefs(links: readonly NavLink[]): string[] {
  return links.map((link) => link.href);
}

const ALL_PERMISSIONS = appNavLinks.flatMap((link) => link.permissions);

describe("visibleNavLinks", () => {
  it("tautan tanpa izin selalu tampil, meski izin sesi kosong", () => {
    const open: NavLink = { href: "/app/open", label: () => "open", permissions: [] };
    expect(hrefs(visibleNavLinks([open], []))).toEqual(["/app/open"]);
  });

  it("menyembunyikan tautan yang izinnya tidak dipegang", () => {
    const links: NavLink[] = [
      { href: "/app/ledger", label: () => "ledger", permissions: ["ledger.journal.read"] },
      { href: "/app/teller", label: () => "teller", permissions: ["teller.transaction.post"] },
    ];
    expect(hrefs(visibleNavLinks(links, ["teller.transaction.post"]))).toEqual(["/app/teller"]);
    expect(hrefs(visibleNavLinks(links, []))).toEqual([]);
  });

  it("lebih dari satu izin = semuanya harus dipegang", () => {
    const link: NavLink = { href: "/app/x", label: () => "x", permissions: ["a", "b"] };
    expect(visibleNavLinks([link], ["a"])).toEqual([]);
    expect(visibleNavLinks([link], ["a", "b"])).toHaveLength(1);
  });

  it("admin (semua izin) melihat seluruh tautan", () => {
    expect(hrefs(visibleNavLinks(appNavLinks, ALL_PERMISSIONS))).toHaveLength(appNavLinks.length);
  });

  it("teller tanpa izin baca parameter hanya melihat layar teller", () => {
    const teller = [
      "teller.session.open",
      "teller.session.close",
      "teller.session.read",
      "teller.transaction.post",
      "teller.vault.read",
      "deposit.account.read",
      "party.party.read",
    ];
    expect(hrefs(visibleNavLinks(appNavLinks, teller))).toEqual(["/app/teller", "/app/vault"]);
  });

  it("maker parameter (tanpa ledger.journal.read) tidak melihat buku besar", () => {
    const maker = ALL_PERMISSIONS.filter((code) => code !== "ledger.journal.read");
    expect(hrefs(visibleNavLinks(appNavLinks, maker))).toEqual([
      "/app/ledger/admin",
      "/app/teller",
      "/app/vault",
      "/app/accounts/open",
      "/app",
      "/app/products",
      "/app/users",
    ]);
  });

  it("hanya izin baca buku besar: item admin buku besar tersembunyi", () => {
    const reader = ["ledger.journal.read", "ledger.period.read", "ledger.coa.read"];
    expect(hrefs(visibleNavLinks(appNavLinks, reader))).toEqual(["/app/ledger"]);
  });

  it("tanpa izin mana pun tidak ada item admin buku besar", () => {
    const codes = appNavLinks.find((link) => link.href === "/app/ledger/admin");
    expect(codes?.permissions).toEqual(["ledger.period.manage"]);
    expect(visibleNavLinks(appNavLinks, ["ledger.coa.manage"])).toEqual([]);
  });

  it("layar pengguna hanya tampil dengan platform.user.manage", () => {
    expect(hrefs(visibleNavLinks(appNavLinks, ["platform.user.manage"]))).toEqual(["/app/users"]);
    expect(hrefs(visibleNavLinks(appNavLinks, []))).toEqual([]);
  });
});

describe("sessionPermissions", () => {
  it("memakai izin sesi bila ada", () => {
    expect(sessionPermissions({ permissions: ["a", "b"] })).toEqual(["a", "b"]);
  });

  it("sesi kosong/null = daftar kosong (fail-closed, bukan menampilkan semuanya)", () => {
    expect(sessionPermissions(null)).toEqual([]);
    expect(sessionPermissions(undefined)).toEqual([]);
    expect(sessionPermissions({})).toEqual([]);
  });
});
