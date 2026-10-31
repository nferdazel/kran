<script module lang="ts">
  import type { Snippet } from "svelte";

  /** Satu kolom tabel data (DESIGN §6). */
  export interface DataColumn {
    /** Nama field pada objek baris. */
    key: string;
    /** Teks judul kolom; simbol mata uang ikut di sini ("Saldo (IDR)") sesuai DESIGN §6. */
    label: string;
    align?: "start" | "end";
    /** Nilai diformat dengan `formatMoney` dan dirender `kran-money`. */
    numerics?: boolean;
    /**
     * Sel kolom ini dirender `<th scope="row">`: kolom kunci yang menamai baris (mis. kode
     * produk). Pembaca layar mengumumkannya bersama tiap sel lain di baris yang sama
     * (DESIGN §6). Hanya satu kolom per tabel yang sebaiknya memakainya.
     */
    rowHeader?: boolean;
  }

  /** Baris tabel: record apa adanya dari pemanggil, tanpa menyalin/mengarang field. */
  export type DataRow = Record<string, unknown>;

  export interface DataSort {
    key: string;
    dir: "asc" | "desc";
  }

  export interface DataActions {
    /** Judul kolom aksi. Teks tidak dikarang komponen (i18n milik pemanggil). */
    label: string;
    cell: Snippet<[DataRow]>;
  }
</script>

<script lang="ts">
  /**
   * Kerangka tabel data (DESIGN §6): `<caption>`, `<th scope="col">`, `aria-sort` pada kolom yang
   * sedang terurut, dan pembungkus bergulir `role="region"` + `tabindex="0"` + `aria-label`.
   *
   * Presentasional: tanpa fetch, tanpa state sortir, tanpa aksi baris bawaan. Urutan baris, isi sel,
   * dan kontrol sortir milik pemanggil. `sort` hanya menyatakan kolom mana yang sedang terurut
   * (`aria-sort`); komponen tidak merender tombol sortir yang belum punya perilaku. Sortir
   * interaktif menyusul bersama CSS-nya.
   *
   * Angka: kolom `numerics` selalu lewat `formatMoney` dan memakai kelas `kran-money` (rata kanan,
   * digit tetap). Sel `null`/`undefined` dibiarkan kosong — bukan diisi nol karangan.
   */
  import { formatMoney } from "../money.js";

  interface Props {
    /** Wajib: `<caption>` adalah satu-satunya nama tabel yang dibacakan pembaca layar. */
    caption: string;
    /** Nama region bergulir. Bawaan = `caption`; diisi terpisah bila pemanggil sudah punya
     *  konvensi nama region (mis. "Tabel: <judul bagian>"). */
    ariaLabel?: string;
    columns: DataColumn[];
    rows: DataRow[];
    sort?: DataSort;
    /** Nama field pada baris yang stabil, dipakai sebagai key `{#each}`. */
    rowKey: string;
    /** Locale angka untuk kolom `numerics` (aplikasi ini dwibahasa id/en). */
    locale?: string;
    actions?: DataActions;
    /**
     * Sembunyikan `<caption>` secara visual, bukan dari pembaca layar. Dipakai saat tabel sudah
     * diberi judul oleh `<h2>` bagian: nama tabel tetap dibacakan, teksnya tidak diulang di layar.
     */
    captionHidden?: boolean;
  }

  let {
    caption,
    ariaLabel,
    columns,
    rows,
    sort,
    rowKey,
    locale = "id-ID",
    actions,
    captionHidden = false,
  }: Props = $props();

  function headerClass(column: DataColumn): string | undefined {
    return column.align === "end" || column.numerics === true ? "kran-num" : undefined;
  }

  function cellClass(column: DataColumn): string | undefined {
    if (column.numerics === true) return "kran-num kran-money";
    return column.align === "end" ? "kran-num" : undefined;
  }

  function ariaSort(column: DataColumn): "ascending" | "descending" | undefined {
    if (sort === undefined || sort.key !== column.key) return undefined;
    return sort.dir === "asc" ? "ascending" : "descending";
  }

  function cellText(row: DataRow, column: DataColumn): string {
    const value = row[column.key];
    if (value === null || value === undefined) return "";
    const text = String(value);
    if (column.numerics !== true) return text;
    return text.trim() === "" ? "" : formatMoney(text, { locale });
  }
</script>

<!-- Region bergulir wajib bisa difokus dengan keyboard (WCAG 2.1.1) dan DESIGN §6 meminta tepat pola
     ini: `role="region"` + `tabindex="0"` + `aria-label`. Kompiler Svelte menandai `tabindex` pada
     elemen noninteraktif; di sini fokus itulah tujuannya, bukan efek samping. -->
<!-- svelte-ignore a11y_no_noninteractive_tabindex -->
<div class="kran-table-wrap" role="region" tabindex="0" aria-label={ariaLabel ?? caption}>
  <table class="kran-table">
    <caption class={captionHidden ? "kran-visually-hidden" : undefined}>{caption}</caption>
    <thead>
      <tr>
        {#each columns as column (column.key)}
          <th scope="col" class={headerClass(column)} aria-sort={ariaSort(column)}>
            {column.label}
          </th>
        {/each}
        {#if actions}
          <th scope="col">{actions.label}</th>
        {/if}
      </tr>
    </thead>
    <tbody>
      {#each rows as row, index (row[rowKey] ?? index)}
        <tr>
          {#each columns as column (column.key)}
            {#if column.rowHeader === true}
              <th scope="row" class={cellClass(column)}>{cellText(row, column)}</th>
            {:else}
              <td class={cellClass(column)}>{cellText(row, column)}</td>
            {/if}
          {/each}
          {#if actions}
            <td>{@render actions.cell(row)}</td>
          {/if}
        </tr>
      {/each}
    </tbody>
  </table>
</div>
