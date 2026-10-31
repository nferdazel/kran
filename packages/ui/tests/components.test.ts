import { createRawSnippet } from "svelte";
import { render } from "svelte/server";
import { describe, expect, it } from "vitest";

import Alert from "../src/components/Alert.svelte";
import Button from "../src/components/Button.svelte";
import DataTable from "../src/components/DataTable.svelte";
import EmptyState from "../src/components/EmptyState.svelte";
import Field from "../src/components/Field.svelte";
import Money from "../src/components/Money.svelte";
import StatusBadge from "../src/components/StatusBadge.svelte";

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
});

type FieldParams = {
  id: string;
  describedby: string | undefined;
  invalid: boolean | undefined;
  required: boolean;
};

/* Kontrol tiruan: memasang nilai yang diterima dari `Field` seperti yang wajib dilakukan pemakai. */
const control = createRawSnippet((field: () => FieldParams) => ({
  render: () => {
    const value = field();
    const describedby =
      value.describedby === undefined ? "" : ` aria-describedby="${value.describedby}"`;
    const invalid = value.invalid === undefined ? "" : ` aria-invalid="${value.invalid}"`;
    const required = value.required ? " required" : "";
    return `<input id="${value.id}"${describedby}${invalid}${required} />`;
  },
}));

describe("Field", () => {
  it("label permanen terhubung ke kontrol lewat for/id", () => {
    const { body: html } = render(Field, {
      props: { label: "Nominal setor", id: "amount", children: control },
    });

    expect(html).toContain('<label class="kran-label" for="amount">');
    expect(html).toContain("Nominal setor");
    expect(html).toContain('<input id="amount"');
  });

  it("hint masuk aria-describedby dengan id turunan", () => {
    const { body: html } = render(Field, {
      props: {
        label: "Nominal setor",
        id: "amount",
        hint: "Digit saja, maksimum 2 desimal.",
        children: control,
      },
    });

    expect(html).toContain('id="amount-hint"');
    expect(html).toContain('aria-describedby="amount-hint"');
    expect(html).not.toContain("aria-invalid");
  });

  it("galat: aria-invalid=true dan aria-describedby memuat hint lalu galat", () => {
    const { body: html } = render(Field, {
      props: {
        label: "Nominal setor",
        id: "amount",
        hint: "Digit saja.",
        error: "Nominal harus lebih dari 0,00.",
        children: control,
      },
    });

    expect(html).toContain('aria-invalid="true"');
    expect(html).toContain('aria-describedby="amount-hint amount-error"');
    expect(html).toContain('<p class="kran-alert" id="amount-error">');
    expect(html).toContain("Nominal harus lebih dari 0,00.");
  });

  it("galat tanpa hint hanya merujuk id galat", () => {
    const { body: html } = render(Field, {
      props: { label: "Nominal setor", id: "amount", error: "Wajib diisi.", children: control },
    });

    expect(html).toContain('aria-describedby="amount-error"');
  });

  it("required menandai kontrol dan label, tanpa membocorkan teks dekoratif ke pembaca layar", () => {
    const { body: html } = render(Field, {
      props: { label: "Nominal setor", id: "amount", required: true, children: control },
    });

    expect(html).toContain(" required />");
    expect(html).toMatch(/<span aria-hidden="true">\s\*<\/span>/);
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
  it("kegagalan memakai role=alert dengan judul heading", () => {
    const { body: html } = render(Alert, {
      props: {
        tone: "negative",
        title: "Setoran tidak tersimpan",
        children: text("<p>Ulangi transaksi.</p>"),
      },
    });

    expect(html).toContain('role="alert"');
    expect(html).toContain('<h2 class="kran-alert__title">Setoran tidak tersimpan</h2>');
    expect(html).toContain("Ulangi transaksi.");
  });

  it("peringatan juga assertive", () => {
    expect(
      render(Alert, { props: { tone: "warning", title: "Kas belum dibuka" } }).body,
    ).toContain('role="alert"');
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
        title: "Belum ada jurnal bertanggal ini",
        description: "Posting jurnal (F2), atau ubah tanggal.",
      },
    });

    expect(html).toContain('<p class="kran-empty-state__title">Belum ada jurnal bertanggal ini</p>');
    expect(html).toContain('<p class="kran-muted">Posting jurnal (F2), atau ubah tanggal.</p>');
    expect(html).not.toContain("<table");
  });

  it("aksi hanya dirender bila snippet dikirim", () => {
    const withAction = render(EmptyState, {
      props: {
        title: "Belum ada rekening",
        action: text('<button type="button" class="kran-button">Buka rekening</button>'),
      },
    }).body;

    expect(withAction).toContain('class="kran-empty-state__action"');
    expect(withAction).toContain("Buka rekening");
    expect(render(EmptyState, { props: { title: "Belum ada rekening" } }).body).not.toContain(
      "kran-empty-state__action",
    );
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

  it("muted menambah kelas muted, currency hanya diumumkan (bukan diulang di tiap sel)", () => {
    const { body: html } = render(Money, {
      props: { value: "250000", currency: "IDR", muted: true },
    });

    expect(html).toContain('class="kran-money kran-muted"');
    expect(html).toMatch(/<span class="kran-visually-hidden">\sIDR<\/span>/);
    expect(html).not.toContain(">250.000,00 IDR<");
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

describe("DataTable", () => {
  function table(extra: Record<string, unknown> = {}): string {
    return render(DataTable, {
      props: { caption: "Saldo per akun", columns: COLUMNS, rows: ROWS, rowKey: "code", ...extra },
    }).body;
  }

  it("caption wajib dirender di dalam <table>", () => {
    const html = table();

    expect(html).toContain("<caption>Saldo per akun</caption>");
    expect(html.indexOf("<caption>")).toBeGreaterThan(html.indexOf("<table"));
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
});
