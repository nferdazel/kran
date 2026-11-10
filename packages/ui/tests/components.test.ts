import { readFileSync } from "node:fs";
import { createRawSnippet } from "svelte";
import { render } from "svelte/server";
import { describe, expect, it } from "vitest";

import Alert from "../src/components/Alert.svelte";
import Button from "../src/components/Button.svelte";
import Checkbox from "../src/components/Checkbox.svelte";
import DataTable from "../src/components/DataTable.svelte";
import EmptyState from "../src/components/EmptyState.svelte";
import ErrorState from "../src/components/ErrorState.svelte";
import Input from "../src/components/Input.svelte";
import LoadingState from "../src/components/LoadingState.svelte";
import Money from "../src/components/Money.svelte";
import Select from "../src/components/Select.svelte";
import StatusBadge from "../src/components/StatusBadge.svelte";
import Textarea from "../src/components/Textarea.svelte";
import { formatMoney } from "../src/money.js";
import DoubleInput from "./fixtures/double-input.svelte";

/**
 * Lapisan komponen `packages/ui` (DESIGN §12 fase 1).
 *
 * Dirender lewat `svelte/server` (string SSR), bukan DOM: kontrak yang diuji adalah keluaran nyata —
 * elemen semantik, `role`, `aria-*`, `<caption>`/`th scope`, dan format uang dari `money.ts`.
 * Tidak ada jsdom/testing-library: keduanya dependensi baru dan butuh ADR.
 */

/** Teks anak sebagai markup apa adanya, seperti yang dikirim pemakai lewat snippet. */
function text(markup: string) {
  return createRawSnippet(() => ({ render: () => markup }));
}

describe("Button", () => {
  it("default: tombol native type=button dengan kelas dasar .kran-button", () => {
    const { body: html } = render(Button, { props: { children: text("Simpan") } });

    expect(html).toMatch(/<button[^>]*class="kran-button"[^>]*type="button"/);
    expect(html).toContain("Simpan");
    // Tidak ada ARIA pengganti elemen: ini benar-benar <button>, bukan <div role="button">.
    expect(html).not.toContain('role="button"');
  });

  it("variant primary memakai modifier .kran-button--primary", () => {
    const { body: html } = render(Button, {
      props: { variant: "primary", children: text("Posting") },
    });

    expect(html).toContain('class="kran-button kran-button--primary"');
  });

  it("variant row dan destructive memakai modifier masing-masing", () => {
    expect(
      render(Button, { props: { variant: "row", children: text("Buka") } }).body,
    ).toContain('class="kran-button kran-button--row"');
    expect(
      render(Button, { props: { variant: "destructive", children: text("Batalkan") } }).body,
    ).toContain('class="kran-button kran-button--destructive"');
  });

  it("atribut tombol lain diteruskan (name/value/aria-label), bukan ditelan komponen", () => {
    const { body: html } = render(Button, {
      props: {
        name: "decision",
        value: "approve",
        "aria-label": "Setujui pengajuan",
        children: text("Setujui"),
      },
    });

    expect(html).toContain('name="decision"');
    expect(html).toContain('value="approve"');
    expect(html).toContain('aria-label="Setujui pengajuan"');
  });

  it("type diteruskan (submit) tanpa mengubah kelas", () => {
    const { body: html } = render(Button, {
      props: { type: "submit", children: text("Kirim") },
    });

    expect(html).toMatch(/<button[^>]*type="submit"/);
  });

  it("disabled merender atribut native disabled (bukan hanya aria)", () => {
    const { body: html } = render(Button, {
      props: { disabled: true, children: text("Simpan") },
    });

    expect(html).toMatch(/<button[^>]*\sdisabled[^>]*>/);
    expect(html).not.toContain('aria-disabled="true"');
  });

  it("loading: aria-busy dan tetap tombol yang tidak bisa diklik", () => {
    const { body: html } = render(Button, {
      props: { loading: true, children: text("Memproses") },
    });

    expect(html).toContain('aria-busy="true"');
    expect(html).toMatch(/<button[^>]*\sdisabled[^>]*>/);
  });

  it("tanpa loading tidak ada aria-busy", () => {
    expect(render(Button, { props: { children: text("Simpan") } }).body).not.toContain("aria-busy");
  });

  it("variant quiet memakai modifier .kran-button--quiet dan bukan modifier varian lain", () => {
    const { body: html } = render(Button, {
      props: { variant: "quiet", children: text("Lewati") },
    });

    expect(html).toContain('class="kran-button kran-button--quiet"');
    for (const other of ["--primary", "--row", "--destructive"]) {
      expect(html).not.toContain(`kran-button${other}`);
    }
  });

  it("size sm memakai kelas 32 dan size md kelas 40", () => {
    expect(
      render(Button, { props: { size: "sm", children: text("Tutup") } }).body,
    ).toContain('class="kran-button kran-button--sm"');
    expect(
      render(Button, { props: { size: "md", children: text("Simpan") } }).body,
    ).toContain('class="kran-button kran-button--md"');
  });

  it("tanpa size tombol tetap 40 (token field), bukan 32", () => {
    const html = render(Button, { props: { children: text("Simpan") } }).body;
    const css = readFileSync(new URL("../src/components.css", import.meta.url), "utf8");

    expect(html).not.toContain("kran-button--sm");
    expect(html).not.toContain("kran-button--md");
    expect(css).toMatch(/^\.kran-button \{[^}]*min-block-size: var\(--control-height-primary\)/m);
  });

  it("variant row tanpa size tetap 32 supaya baris tabel tidak berubah", () => {
    const html = render(Button, { props: { variant: "row", children: text("Buka") } }).body;
    const css = readFileSync(new URL("../src/components.css", import.meta.url), "utf8");

    expect(html).toContain('class="kran-button kran-button--row"');
    expect(html).not.toContain("kran-button--md");
    expect(css).toMatch(/^\.kran-button--row \{[^}]*min-block-size: var\(--control-height\)/m);
  });

  it("size menang atas row bila keduanya diberikan", () => {
    const html = render(Button, {
      props: { variant: "row", size: "md", children: text("Buka") },
    }).body;
    const css = readFileSync(new URL("../src/components.css", import.meta.url), "utf8");
    const sizeRuleAt = css.search(/^\.kran-button--md \{/m);
    const rowRuleAt = css.search(/^\.kran-button--row \{/m);

    expect(html).toContain("kran-button--md");
    // Aturan ukuran harus menang lewat urutan sumber, bukan !important.
    expect(sizeRuleAt).toBeGreaterThan(rowRuleAt);
    expect(css.match(/^\.kran-button--md \{[^}]*\}/m)?.[0] ?? "").not.toContain("!important");
  });

  it("loading mempertahankan label di DOM, bukan menggantinya dengan spinner", () => {
    const { body: html } = render(Button, {
      props: { loading: true, children: text("Menyimpan") },
    });

    expect(html).toContain("Menyimpan");
    expect(html).toContain('aria-busy="true"');
  });
});

/** Id kontrol hasil `$props.id()`, diekstrak dari keluaran SSR (nilainya tidak boleh dihardcode). */
function controlId(html: string, tag: "input" | "select" | "textarea"): string {
  const match = html.match(new RegExp(`<${tag}[^>]*\\sid="([^"]+)"`));
  expect(match, `tidak ada <${tag}> ber-id di keluaran: ${html}`).not.toBeNull();
  return match![1];
}

describe("Input", () => {
  it("label permanen terhubung ke kontrol lewat id yang dibuat kontrol itu sendiri", () => {
    const { body: html } = render(Input, { props: { label: "Nominal setor" } });
    const id = controlId(html, "input");

    expect(html).toContain(`<label class="kran-label" for="${id}">`);
    expect(html).toContain("Nominal setor");
    expect(html).toContain('class="kran-control"');
  });

  it("dua kontrol berlabel sama tidak berbagi id", () => {
    const { body: html } = render(DoubleInput, {});
    const ids = [...html.matchAll(/<input[^>]*\sid="([^"]+)"/g)].map((match) => match[1]);

    expect(ids).toHaveLength(2);
    expect(new Set(ids).size).toBe(2);
    for (const id of ids) {
      expect(html).toContain(`for="${id}"`);
    }
  });

  it("hint saja: aria-describedby hanya berisi id hint, tanpa aria-invalid", () => {
    const { body: html } = render(Input, {
      props: { label: "Nominal setor", hint: "Digit saja." },
    });
    const id = controlId(html, "input");

    expect(html).toContain(`id="${id}-hint"`);
    expect(html).toContain(`aria-describedby="${id}-hint"`);
    expect(html).not.toContain("aria-invalid");
  });

  it("galat saja: satu id galat, aria-invalid=true, dan teks galat dirender", () => {
    const { body: html } = render(Input, {
      props: { label: "Nominal setor", error: "Wajib diisi." },
    });
    const id = controlId(html, "input");

    expect(html).toContain(`aria-describedby="${id}-error"`);
    expect(html).toContain('aria-invalid="true"');
    expect(html).toContain(`<p class="kran-alert" id="${id}-error">`);
    expect(html).toContain("Wajib diisi.");
  });

  it("hint dan galat: urutannya hint lalu galat", () => {
    const { body: html } = render(Input, {
      props: { label: "Nominal setor", hint: "Digit saja.", error: "Wajib diisi." },
    });
    const id = controlId(html, "input");

    expect(html).toContain(`aria-describedby="${id}-hint ${id}-error"`);
  });

  it("tanpa hint dan galat tidak ada rujukan deskripsi yang menggantung", () => {
    const { body: html } = render(Input, { props: { label: "Nominal setor" } });

    expect(html).not.toContain("aria-describedby");
    expect(html).not.toContain("-hint");
    expect(html).not.toContain("-error");
  });

  it("required menandai kontrol dan label tanpa membocorkan tanda dekoratif ke pembaca layar", () => {
    const { body: html } = render(Input, { props: { label: "Nominal setor", required: true } });

    expect(html).toMatch(/<input[^>]*\srequired/);
    expect(html).toContain('<span class="kran-required" aria-hidden="true">*</span>');
  });
});

describe("Textarea", () => {
  it("memakai elemen textarea asli dengan label terhubung", () => {
    const { body: html } = render(Textarea, {
      props: { label: "Alasan", hint: "Maksimum 200 karakter.", rows: 3 },
    });
    const id = controlId(html, "textarea");

    expect(html).toContain(`<label class="kran-label" for="${id}">`);
    expect(html).toContain('class="kran-control"');
    expect(html).toContain(`aria-describedby="${id}-hint"`);
  });
});

describe("Select", () => {
  const options = createRawSnippet(() => ({
    render: () => '<option value="">Pilih</option><option value="A">Aktif</option>',
  }));

  it("tetap elemen select native dengan label terhubung", () => {
    const { body: html } = render(Select, {
      props: { label: "Status", children: options },
    });
    const id = controlId(html, "select");

    expect(html).toContain(`<label class="kran-label" for="${id}">`);
    expect(html).not.toContain('role="listbox"');
    expect(html).toContain('<option value="A">Aktif</option>');
    expect(html).toContain('class="kran-control"');
  });

  it("galat memindahkan aria-invalid dan deskripsi ke elemen select", () => {
    const { body: html } = render(Select, {
      props: { label: "Status", error: "Pilih salah satu.", children: options },
    });
    const id = controlId(html, "select");

    expect(html).toContain('aria-invalid="true"');
    expect(html).toContain(`aria-describedby="${id}-error"`);
  });
});

describe("Checkbox", () => {
  it("tetap input type=checkbox asli, bukan peran buatan", () => {
    const { body: html } = render(Checkbox, { props: { label: "Bisa diposting" } });
    const id = controlId(html, "input");

    expect(html).toContain('type="checkbox"');
    expect(html).toContain('class="kran-checkbox__box"');
    expect(html).not.toContain('role="checkbox"');
    expect(html).toContain(`<label class="kran-label" for="${id}">`);
  });

  it("hint tetap terhubung lewat aria-describedby", () => {
    const { body: html } = render(Checkbox, {
      props: { label: "Bisa diposting", hint: "Hanya akun tipe aset." },
    });
    const id = controlId(html, "input");

    expect(html).toContain(`id="${id}-hint"`);
    expect(html).toContain(`aria-describedby="${id}-hint"`);
  });
});

describe("Kontrol form v2", () => {
  it("tiga kontrol inti tidak membawa warna hex mentah", () => {
    const files = ["Input", "Select", "Checkbox"].map((name) =>
      readFileSync(new URL(`../src/components/${name}.svelte`, import.meta.url), "utf8"),
    );

    for (const source of files) {
      expect(source).not.toMatch(/#[0-9a-fA-F]{3,6}/);
    }
  });

  it("Field sudah tidak ada: satu cara membangun kontrol", () => {
    expect(() =>
      readFileSync(new URL("../src/components/Field.svelte", import.meta.url), "utf8"),
    ).toThrow();
  });
});

describe("StatusBadge", () => {
  it("tone positif memakai badge ok, teks tetap dari pemakai", () => {
    const { body: html } = render(StatusBadge, {
      props: { tone: "positive", children: text("Tersimpan") },
    });

    expect(html).toContain('class="kran-badge kran-badge--ok"');
    expect(html).toContain("Tersimpan");
  });

  it("setiap tone punya kelas berbeda, netral tanpa modifier", () => {
    expect(
      render(StatusBadge, { props: { tone: "negative", children: text("Gagal") } }).body,
    ).toContain('class="kran-badge kran-badge--danger"');
    expect(
      render(StatusBadge, { props: { tone: "warning", children: text("Selisih") } }).body,
    ).toContain('class="kran-badge kran-badge--warning"');
    expect(
      render(StatusBadge, { props: { tone: "info", children: text("Info") } }).body,
    ).toContain('class="kran-badge kran-badge--info"');
    expect(
      render(StatusBadge, { props: { tone: "neutral", children: text("Draf") } }).body,
    ).toContain('class="kran-badge"');
  });
});

describe("Alert", () => {
  it("kegagalan memakai role=alert dengan judul non-heading", () => {
    const { body: html } = render(Alert, {
      props: {
        tone: "negative",
        title: "Setoran tidak tersimpan",
        children: text("<p>Ulangi transaksi.</p>"),
      },
    });

    expect(html).toContain('role="alert"');
    expect(html).toContain('<p class="kran-alert__title">Setoran tidak tersimpan</p>');
    expect(html).not.toContain("<h2");
    expect(html).toContain("Ulangi transaksi.");
  });

  it("peringatan tidak assertive: hanya kegagalan yang memotong pembaca layar", () => {
    const { body: html } = render(Alert, { props: { tone: "warning", title: "Kas belum dibuka" } });

    expect(html).toContain('role="status"');
    expect(html).not.toContain('role="alert"');
  });

  it("tone lain memakai role=status (polite)", () => {
    const { body: html } = render(Alert, { props: { tone: "info", title: "Tersimpan" } });

    expect(html).toContain('role="status"');
    expect(html).not.toContain('role="alert"');
  });

  it("referensi transaksi dirender apa adanya", () => {
    const { body: html } = render(Alert, {
      props: { tone: "negative", title: "Gagal", reference: "TRX-20261031-0007" },
    });

    expect(html).toContain('<p class="kran-print-ref">TRX-20261031-0007</p>');
  });

  it("tanpa aksi dan referensi tidak mengarang isi", () => {
    const { body: html } = render(Alert, { props: { tone: "positive", title: "Tersimpan" } });

    expect(html).not.toContain("kran-print-ref");
    expect(html).not.toContain("<button");
  });
});

describe("EmptyState", () => {
  it("judul + penjelasan, tanpa data contoh", () => {
    const { body: html } = render(EmptyState, {
      props: {
        kind: "no-data",
        title: "Belum ada jurnal bertanggal ini",
        description: "Posting jurnal (F2), atau ubah tanggal.",
      },
    });

    expect(html).toContain('<p class="kran-empty-state__title">Belum ada jurnal bertanggal ini</p>');
    expect(html).toContain('<p class="kran-muted">Posting jurnal (F2), atau ubah tanggal.</p>');
    expect(html).not.toContain("<table");
  });

  it("kind=no-match merender aksi yang dikirim pemakai", () => {
    const withAction = render(EmptyState, {
      props: {
        kind: "no-match",
        title: "Tidak ada pinjaman yang cocok.",
        action: text('<button type="button" class="kran-button">Hapus filter</button>'),
      },
    }).body;

    expect(withAction).toContain('class="kran-empty-state__action"');
    expect(withAction).toContain("Hapus filter");
  });

  it("kind=no-data tidak merender aksi meski pemakai mengirimnya", () => {
    const html = render(EmptyState, {
      props: {
        kind: "no-data",
        title: "Belum ada rekening",
        action: text('<button type="button" class="kran-button">Buka rekening</button>'),
      },
    }).body;

    expect(html).not.toContain("kran-empty-state__action");
    expect(html).not.toContain("Buka rekening");
  });

  it("kind=denied punya kalimatnya sendiri dan tidak membawa live-region role", () => {
    const html = render(EmptyState, {
      props: {
        kind: "denied",
        title: "Akses terbatas",
        description: "Anda tidak memiliki izin membaca kas besar.",
      },
    }).body;

    expect(html).toContain("Akses terbatas");
    expect(html).toContain("Anda tidak memiliki izin membaca kas besar.");
    expect(html).toContain('data-kind="denied"');
    expect(html).not.toMatch(/role="(status|alert|log)"/);
  });

  it("tanpa kind = keadaan lain, bukan ketiga jenis itu", () => {
    const html = render(EmptyState, {
      props: { title: "Pinjaman tidak ditemukan atau bukan di cabang Anda." },
    }).body;

    expect(html).toContain("Pinjaman tidak ditemukan");
    expect(html).not.toMatch(/role="(status|alert|log)"/);
  });
});

describe("LoadingState", () => {
  it("satu-satunya keadaan dengan role=status dan aria-busy", () => {
    const html = render(LoadingState, { props: { label: "Memuat pinjaman…" } }).body;

    expect(html).toContain('role="status"');
    expect(html).toContain('aria-busy="true"');
    expect(html).toContain("Memuat pinjaman…");
  });
});

describe("ErrorState", () => {
  it("judul, badan, dan label retry dari pemakai", () => {
    const html = render(ErrorState, {
      props: {
        title: "Pinjaman tidak bisa dimuat.",
        body: "Periksa koneksi lalu coba lagi.",
        retryLabel: "Coba lagi",
      },
    }).body;

    expect(html).toContain("Pinjaman tidak bisa dimuat.");
    expect(html).toContain("Periksa koneksi lalu coba lagi.");
    expect(html).toContain("Coba lagi");
    expect(html).not.toMatch(/role="(status|alert|log)"/);
  });

  it("tidak punya label retry bawaan yang tertukar dengan reload", () => {
    const source = readFileSync(new URL("../src/components/ErrorState.svelte", import.meta.url), "utf8");

    expect(source).not.toContain("Muat ulang");
  });
});

describe("Terminologi i18n (T-292)", () => {
  const read = (locale: string): Record<string, string> =>
    JSON.parse(
      readFileSync(new URL(`../../i18n/messages/${locale}.json`, import.meta.url), "utf8"),
    ) as Record<string, string>;

  it("tidak ada nilai id yang masih menyebut vault atau teller", () => {
    const offenders = Object.entries(read("id"))
      .filter(([, value]) => /vault|teller/i.test(value))
      .map(([key]) => key);

    expect(offenders).toEqual([]);
  });

  it("nilai en tidak diubah: 27 nilai masih memakai istilah itu", () => {
    const matches = Object.values(read("en")).filter((value) => /vault|teller/i.test(value));

    expect(matches).toHaveLength(27);
  });
});

describe("Money", () => {
  it("memakai formatMoney (id-ID, 2 desimal) dan kelas kran-money", () => {
    const { body: html } = render(Money, { props: { value: "1500000.00" } });

    expect(html).toContain('<span class="kran-money">');
    expect(html).toContain("1.500.000,00");
  });

  it("pembulatan half-even milik money.ts, bukan formatter sendiri", () => {
    expect(render(Money, { props: { value: "1.005" } }).body).toContain("1,00");
    expect(render(Money, { props: { value: "1.015" } }).body).toContain("1,02");
  });

  it("negatif membawa minus di depan digit", () => {
    expect(render(Money, { props: { value: "-12.5" } }).body).toContain("-12,50");
  });

  it("merender keluaran identik untuk setiap pemanggil (tidak ada prop currency)", () => {
    const plain = render(Money, { props: { value: "250000" } }).body;
    const withExCurrency = render(Money, {
      props: { value: "250000", currency: "IDR" } as never,
    }).body;

    expect(withExCurrency).toBe(plain);
    expect(plain).not.toContain("kran-visually-hidden");
    expect(plain).not.toContain("IDR");
  });

  it("locale diteruskan: en-US memakai pemisah Inggris", () => {
    expect(render(Money, { props: { value: "1234567.89", locale: "en-US" } }).body).toContain(
      "1,234,567.89",
    );
    expect(render(Money, { props: { value: "1234567.89" } }).body).toContain("1.234.567,89");
  });

  it("nilai kosong dirender kosong, bukan melempar atau mengarang nol", () => {
    const { body: html } = render(Money, { props: { value: "   " } });

    expect(html).not.toContain("NaN");
    expect(html).not.toContain("0,00");
  });
});

const COLUMNS = [
  { key: "code", label: "Kode" },
  { key: "name", label: "Akun" },
  { key: "balance", label: "Saldo (IDR)", align: "end" as const, numerics: true },
];

const ROWS = [
  { code: "101", name: "Kas", balance: "1234567.89" },
  { code: "201", name: "Simpanan anggota", balance: null },
];

/**
 * Teks setiap sel uang di HTML apa adanya. Markup bersarang ikut dibaca, bukan dilewati: sel
 * yang menyembunyikan unit di dalam `<span>` harus sampai ke asersi dan gagal di sana.
 */
function moneyCellTexts(html: string): string[] {
  const cells = html.match(/<td class="kran-num kran-money[^"]*">[\s\S]*?<\/td>/g) ?? [];
  return cells.map((cell) => cell.replace(/<[^>]+>/g, "").trim());
}

/** Satu-satunya bentuk sel uang yang boleh tampil: angka tanpa simbol mata uang. */
function expectAmountOnly(cells: string[]): void {
  for (const text of cells) {
    if (text === "") continue;
    expect(text).toMatch(/^-?\d{1,3}(\.\d{3})*,\d{2}$/);
    expect(text).not.toMatch(/IDR|Rp/);
  }
}

describe("DataTable", () => {
  function table(extra: Record<string, unknown> = {}): string {
    return render(DataTable, {
      props: { caption: "Saldo per akun", columns: COLUMNS, rows: ROWS, rowKey: "code", ...extra },
    }).body;
  }

  it("caption wajib dirender di dalam <table>", () => {
    const html = table();

    expect(html).toMatch(/<table class="kran-table"><caption>Saldo per akun<\/caption>/);
  });

  it("pembungkus adalah region berlabel yang bisa digulir dengan keyboard", () => {
    const html = table();

    expect(html).toMatch(
      /<div[^>]*class="kran-table-wrap"[^>]*role="region"[^>]*tabindex="0"[^>]*aria-label="Saldo per akun"/,
    );
  });

  it("header memakai th scope=col", () => {
    const html = table();

    expect(html).toContain('<th scope="col">Kode</th>');
    expect(html).toContain('<th scope="col">Akun</th>');
    expect(html).toContain('<th scope="col" class="kran-num">Saldo (IDR)</th>');
  });

  it("aria-sort hanya pada kolom yang sedang terurut", () => {
    const html = table({ sort: { key: "code", dir: "asc" } });

    expect(html).toContain('<th scope="col" aria-sort="ascending">Kode</th>');
    expect(html.match(/aria-sort/g) ?? []).toHaveLength(1);
  });

  it("arah desc menjadi descending", () => {
    const html = table({ sort: { key: "balance", dir: "desc" } });

    expect(html).toContain('<th scope="col" class="kran-num" aria-sort="descending">Saldo (IDR)</th>');
  });

  it("kolom numerics diformat money.ts dengan kelas kran-num kran-money", () => {
    expect(table()).toContain(
      '<td class="kran-num kran-money">1.234.567,89</td>',
    );
  });

  it("locale diteruskan ke kolom numerics", () => {
    expect(table({ locale: "en-US" })).toContain(
      '<td class="kran-num kran-money">1,234,567.89</td>',
    );
  });

  it("unit uang hanya di header kolom, tidak pernah di tiap sel", () => {
    const html = table();

    expect(html).toContain("Saldo (IDR)");
    const cells = moneyCellTexts(html);
    expect(cells.length).toBeGreaterThan(0);
    expectAmountOnly(cells);
  });

  it("penjaga sel uang membaca markup bersarang, bukan melewatinya", () => {
    const fixture =
      '<td class="kran-num kran-money">1.234,56</td>' +
      '<td class="kran-num kran-money"><span class="kran-visually-hidden">IDR</span>7.654,32</td>';
    const cells = moneyCellTexts(fixture);

    expect(cells).toHaveLength(2);
    expect(cells[1]).toBe("IDR7.654,32");
    // Asersi yang sama dengan tabel sungguhan harus gagal pada fixture ini.
    expect(() => expectAmountOnly(cells)).toThrow();
  });

  it("nilai negatif memakai minus di depan, tanpa kurung, di ink normal", () => {
    const rows = [{ code: "301", name: "Koreksi", balance: "-1500000.00" }];
    const html = table({ rows });
    const cell = moneyCellTexts(html).find((text) => text !== "") ?? "";

    expect(cell).toBe(formatMoney("-1500000.00"));
    expect(cell).not.toMatch(/[()]/);
    expect(html).not.toContain("kran-muted");
  });

  it("sel uang tidak pernah pecah baris", () => {
    const css = readFileSync(new URL("../src/components.css", import.meta.url), "utf8");

    // Minus tidak boleh terpisah dari angkanya.
    expect(css).toMatch(
      /@media screen \{[^@]*?\.kran-table \.kran-money \{[^}]*white-space: nowrap/,
    );
  });

  it("kolom uang mencadangkan lebar untuk nilai 3 dan 7 digit", () => {
    const rows = [
      { code: "101", name: "Kas", balance: "999.00" },
      { code: "102", name: "Bank", balance: "1234567.00" },
    ];
    const html = table({ rows });
    const cells = html.match(/<td class="kran-num kran-money">/g) ?? [];

    expect(cells).toHaveLength(2);
    const css = readFileSync(new URL("../src/components.css", import.meta.url), "utf8");
    // Cadangan lebar berlaku di semua sel uang `.kran-table`, jadi tabel tangan seperti
    // `/app/ledger` ikut dapat tanpa kelas tambahan di halaman.
    expect(css).toMatch(
      /@media screen \{[^@]*?\.kran-table \.kran-money \{[^}]*min-inline-size: 12ch/,
    );
  });

  it("hanya ada satu formatter uang", () => {
    const source = readFileSync(new URL("../src/money.ts", import.meta.url), "utf8");

    expect(source.match(/export function format/g) ?? []).toHaveLength(1);
  });

  it("nilai kosong tidak diganti nol karangan", () => {
    expect(table()).toContain('<td class="kran-num kran-money"></td>');
  });

  it("teks biasa tidak diformat sebagai uang", () => {
    expect(table()).toContain("<td>Kas</td>");
  });

  it("kolom aksi opsional memakai label dari pemakai dan snippet per baris", () => {
    const html = table({
      actions: {
        label: "Aksi",
        cell: createRawSnippet((row: () => Record<string, unknown>) => ({
          render: () => `<button type="button" class="kran-button">Buka ${row().code}</button>`,
        })),
      },
    });

    expect(html).toContain('<th scope="col">Aksi</th>');
    expect(html).toContain("Buka 101");
    expect(html).toContain("Buka 201");
  });

  it("tanpa aksi tidak ada kolom tambahan", () => {
    expect(table()).not.toContain("kran-button");
  });

  it("density compact memakai kelas baris 36, bawaan tetap 40", () => {
    expect(table({ density: "compact" })).toContain("kran-table--compact");
    expect(table()).not.toContain("kran-table--compact");
  });

  it("totals dirender di tfoot dengan sel pertama th scope=row", () => {
    const html = table({ totals: { code: "Total", balance: "1234567.89" } });

    expect(table()).not.toContain("<tfoot");
    expect(html).toMatch(/<tfoot[^>]*>[\s\S]*<th scope="row">Total<\/th>/);
    expect(html).toContain('<td class="kran-num kran-money">1.234.567,89</td>');
  });

  it("selectedKeys menandai tepat satu baris, baris lain false", () => {
    const html = table({ selectedKeys: ["101"] });
    const rowTags = html.match(/<tr[^>]*>/g) ?? [];

    expect(rowTags.filter((tag) => tag.includes('aria-selected="true"'))).toHaveLength(1);
    expect(rowTags.filter((tag) => tag.includes("kran-table__selected"))).toHaveLength(1);
    expect(rowTags[1]).toContain('aria-selected="true"');
    expect(rowTags[1]).toContain("kran-table__selected");
    expect(rowTags[2]).toContain('aria-selected="false"');
    expect(rowTags[2]).not.toContain("kran-table__selected");
  });

  it("seleksi mengikuti rowKey saat baris diurutkan ulang", () => {
    const html = table({ rows: [ROWS[1], ROWS[0]], selectedKeys: ["101"] });
    const rowTags = html.match(/<tr[^>]*>/g) ?? [];

    expect(rowTags[1]).toContain('aria-selected="false"');
    expect(rowTags[2]).toContain('aria-selected="true"');
  });

  it("rowLines merender dua baris hanya saat baris menyediakan baris kedua", () => {
    const columns = [
      { key: "code", label: "Kode", rowHeader: true, secondary: "note" },
      { key: "name", label: "Akun" },
      { key: "balance", label: "Saldo (IDR)", align: "end" as const, numerics: true },
    ];
    const rows = [
      { code: "101", name: "Kas", balance: "1234567.89", note: "kas kecil" },
      { code: "201", name: "Simpanan anggota", balance: null },
    ];
    const html = table({ columns, rows, rowLines: true });

    expect(html).toContain('<span class="kran-table__primary">101</span>');
    expect(html).toContain('<span class="kran-table__secondary">kas kecil</span>');
    expect(html.match(/<span class="kran-table__secondary">/g) ?? []).toHaveLength(1);
  });

  it("nowrap menambahkan kran-nowrap hanya pada kolom itu, header dan sel", () => {
    const columns = [
      { key: "code", label: "Kode" },
      { key: "disbursedOn", label: "Cair", nowrap: true },
    ];
    const rows = [{ code: "101", disbursedOn: "10 November 2026" }];
    const html = table({ columns, rows });

    expect(html).toContain('<th scope="col" class="kran-nowrap">Cair</th>');
    expect(html).toContain('<td class="kran-nowrap">10 November 2026</td>');
    expect(html.match(/kran-nowrap/g) ?? []).toHaveLength(2);
  });

  it("kolom berbaris kedua dibatasi lebarnya, kolom biasa tidak", () => {
    const columns = [
      { key: "code", label: "Kode" },
      { key: "name", label: "Anggota", secondary: "id" },
    ];
    const rows = [{ code: "101", name: "Kas", id: "e2e00000-0000-4000-8000-000000000001" }];
    const html = table({ columns, rows, rowLines: true });

    expect(html).toMatch(
      /<td class="kran-table__secondary-cell"><span class="kran-table__primary">Kas<\/span>/,
    );
    expect(html.match(/kran-table__secondary-cell/g) ?? []).toHaveLength(1);
  });

  it("pembungkus tetap satu tabindex dan satu region meski opsi v2 aktif", () => {
    const html = table({ density: "compact", stickyHeader: true });

    expect(html).toContain("kran-table--sticky");
    expect(html.match(/tabindex="0"/g) ?? []).toHaveLength(1);
    expect(html.match(/role="region"/g) ?? []).toHaveLength(1);
  });
});
