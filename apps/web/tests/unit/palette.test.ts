/**
 * Test unit command palette T-110 (tanpa DOM, tanpa DB).
 *
 * Dijalankan dengan binary vitest milik `packages/ui` (lihat `vitest.d.ts`):
 *   cd apps/web && node ../../packages/ui/node_modules/vitest/vitest.mjs run tests/unit
 *
 * Yang diuji = logika murni: pemetaan sumber nav → aksi, pencarian lintas bahasa, dan aturan
 * `aria-current`. Perilaku dialog (buka, trap, fokus kembali) diuji e2e — itu ranah DOM.
 */
import { describe, expect, it } from "vitest";

import { isActiveHref, appNavLinks } from "#lib/app/nav.js";
import { filterActions, paletteActions, type PaletteSource } from "#lib/app/palette.js";

const LOCALES = ["id", "en"] as const;

/** Sumber tiruan: memisahkan perilaku pencarian dari isi katalog pesan. */
const SOURCES: readonly PaletteSource[] = [
  { href: "/app/ledger", label: (locale) => (locale === "en" ? "Ledger" : "Buku besar") },
  { href: "/app/teller", label: () => "Teller" },
];

describe("paletteActions", () => {
  it("menampilkan label bahasa aktif dan menjadikan semua bahasa kata kunci", () => {
    const actions = paletteActions(SOURCES, "en", LOCALES);
    expect(actions.map((action) => action.label)).toEqual(["Ledger", "Teller"]);
    // Urutan kata kunci mengikuti urutan locale yang diberikan (id lalu en), bukan bahasa aktif.
    expect(actions[0]?.keywords).toEqual(["/app/ledger", "buku besar", "ledger"]);
  });

  it("menghapus kata kunci kembar", () => {
    const actions = paletteActions([SOURCES[1] as PaletteSource], "id", LOCALES);
    expect(actions[0]?.keywords).toEqual(["/app/teller", "teller"]);
  });
});

describe("filterActions", () => {
  const actions = paletteActions(SOURCES, "id", LOCALES);

  it("kueri kosong/spasi = seluruh daftar", () => {
    expect(filterActions(actions, "").length).toEqual(2);
    expect(filterActions(actions, "   ").length).toEqual(2);
  });

  it("substring tanpa peduli huruf besar/kecil", () => {
    expect(filterActions(actions, "BUKU").map((action) => action.href)).toEqual(["/app/ledger"]);
    expect(filterActions(actions, "tell").map((action) => action.href)).toEqual(["/app/teller"]);
  });

  it("menemukan lewat label bahasa lain dan lewat href", () => {
    expect(filterActions(actions, "ledger").map((action) => action.href)).toEqual(["/app/ledger"]);
    expect(filterActions(actions, "app/teller").map((action) => action.href)).toEqual([
      "/app/teller",
    ]);
  });

  it("tanpa kecocokan = daftar kosong (state kosong di UI)", () => {
    expect(filterActions(actions, "pinjaman")).toEqual([]);
  });
});

describe("sumber aksi = nav yang sudah ada", () => {
  it("setiap tautan nav punya tepat satu aksi, tanpa duplikat", () => {
    const actions = paletteActions(appNavLinks, "id", LOCALES);
    expect(actions.map((action) => action.href)).toEqual(
      appNavLinks.map((link) => link.href),
    );
    expect(new Set(actions.map((action) => action.href)).size).toEqual(appNavLinks.length);
    // Aksi = navigasi di dalam aplikasi, bukan URL luar atau perintah mutasi.
    for (const action of actions) expect(action.href.startsWith("/app")).toBeTruthy();
  });

  it("label id dan en sama-sama menemukan tujuan yang sama", () => {
    const actions = paletteActions(appNavLinks, "id", LOCALES);
    for (const link of appNavLinks) {
      for (const locale of LOCALES) {
        const label = link.label(locale);
        expect(filterActions(actions, label).map((action) => action.href)).toContain(link.href);
      }
    }
  });
});

describe("isActiveHref", () => {
  it("`/app` hanya aktif di halaman itu sendiri, bukan di rute turunannya", () => {
    expect(isActiveHref("/app", "/app")).toBeTruthy();
    expect(isActiveHref("/app/ledger", "/app")).toBeFalsy();
    expect(isActiveHref("/app/teller", "/app")).toBeFalsy();
  });

  it("rute lain aktif sebagai awalan", () => {
    expect(isActiveHref("/app/ledger", "/app/ledger")).toBeTruthy();
    expect(isActiveHref("/app/teller", "/app/ledger")).toBeFalsy();
    expect(isActiveHref("/login", "/app/ledger")).toBeFalsy();
  });
});
