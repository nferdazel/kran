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
    /**
     * Nama field pada baris yang menjadi baris kedua redup di sel kolom ini (mis. catatan
     * singkat). Hanya dirender saat `rowLines` aktif dan baris benar-benar punya nilainya;
     * baris tanpa field itu tetap satu baris, tanpa baris kedua kosong.
     */
    secondary?: string;
    /**
     * Nilai sel tidak boleh pecah baris (mis. tanggal "10 November 2026" yang akan menjadi tiga
     * baris di kolom sempit). Dirender sebagai `kran-nowrap` pada `th`/`td` kolom ini.
     */
    nowrap?: boolean;
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
    /** Tinggi baris: `default` 40px (token `--row-height`), `compact` 36px. Bawaan `default`. */
    density?: "default" | "compact";
    /** Header menempel di atas region saat isi digulir. */
    stickyHeader?: boolean;
    /**
     * Baris total di `<tfoot>`: record dengan bentuk sama seperti baris biasa. Sel pertama
     * selalu `<th scope="row">`, sisanya mengikuti tipe kolomnya. Label diambil dari pemanggil
     * (tidak ada teks yang dikarang komponen).
     */
    totals?: DataRow;
    /** Baris dua tingkat: baris utama 13/600, baris kedua 11 redup (lihat `DataColumn.secondary`). */
    rowLines?: boolean;
    /**
     * Key baris (nilai `rowKey`) yang sedang dipilih. Pemanggil yang menyimpan himpunan ini, jadi
     * pilihan ikut bertahan saat baris diurutkan atau halaman berganti. Tanpa prop ini tidak ada
     * atribut `aria-selected` sama sekali.
     */
    selectedKeys?: readonly string[];
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
    density = "default",
    stickyHeader = false,
    totals,
    rowLines = false,
    selectedKeys,
  }: Props = $props();

  const tableClass = $derived(
    [
      "kran-table",
      density === "compact" ? "kran-table--compact" : "",
      stickyHeader ? "kran-table--sticky" : "",
      rowLines ? "kran-table--two-line" : "",
    ]
      .filter(Boolean)
      .join(" "),
  );

  function rowKeyOf(row: DataRow, index: number): string {
    const value = row[rowKey];
    return value === null || value === undefined ? String(index) : String(value);
  }

  function isSelected(row: DataRow, index: number): boolean | undefined {
    if (selectedKeys === undefined) return undefined;
    return selectedKeys.includes(rowKeyOf(row, index));
  }

  function hasSecondary(row: DataRow, column: DataColumn): boolean {
    if (column.secondary === undefined) return false;
    const value = row[column.secondary];
    return value !== null && value !== undefined && String(value).trim() !== "";
  }

  function headerClass(column: DataColumn): string | undefined {
    const classes: string[] = [];
    if (column.align === "end" || column.numerics === true) classes.push("kran-num");
    if (column.nowrap === true) classes.push("kran-nowrap");
    return classes.length === 0 ? undefined : classes.join(" ");
  }

  function cellClass(column: DataColumn): string | undefined {
    const classes: string[] = [];
    if (column.numerics === true) classes.push("kran-num", "kran-money");
    else if (column.align === "end") classes.push("kran-num");
    if (column.nowrap === true) classes.push("kran-nowrap");
    if (rowLines && column.secondary !== undefined) classes.push("kran-table__secondary-cell");
    return classes.length === 0 ? undefined : classes.join(" ");
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
  <table class={tableClass}>
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
      {#each rows as row, index (rowKeyOf(row, index))}
        {@const selected = isSelected(row, index)}
        <tr
          class={selected === true ? "kran-table__selected" : undefined}
          aria-selected={selected}
        >
          {#each columns as column (column.key)}
            {#if column.rowHeader === true}
              {#if rowLines}
                <th scope="row" class={cellClass(column)}>
                  <span class="kran-table__primary">{cellText(row, column)}</span>
                  {#if hasSecondary(row, column)}<span class="kran-table__secondary">{String(row[column.secondary as string])}</span>{/if}
                </th>
              {:else}
                <th scope="row" class={cellClass(column)}>{cellText(row, column)}</th>
              {/if}
            {:else if rowLines}
              <td class={cellClass(column)}>
                <span class="kran-table__primary">{cellText(row, column)}</span>
                {#if hasSecondary(row, column)}<span class="kran-table__secondary">{String(row[column.secondary as string])}</span>{/if}
              </td>
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
    {#if totals}
      <tfoot>
        <tr>
          {#each columns as column, index (column.key)}
            {#if index === 0}
              <th scope="row" class={cellClass(column)}>{cellText(totals, column)}</th>
            {:else}
              <td class={cellClass(column)}>{cellText(totals, column)}</td>
            {/if}
          {/each}
          {#if actions}
            <td></td>
          {/if}
        </tr>
      </tfoot>
    {/if}
  </table>
</div>
