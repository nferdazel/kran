<script lang="ts">
  /**
   * Label + kontrol + hint + pesan galat (DESIGN §7: label permanen, pesan teks +
   * `aria-describedby`, bukan placeholder sebagai label).
   *
   * Kontrol tidak bisa diberi atribut dari sini karena ia dirender `children`. Karena itu nilainya
   * diteruskan sebagai parameter snippet: `id`, `describedby`, `invalid`, `required`. Pemakai
   * wajib memasangnya pada kontrol (`<input … aria-describedby={describedby} aria-invalid={invalid}>`)
   * supaya hubungan label/deskripsi nyata, bukan sekadar visual.
   *
   * Galat **tidak** memakai `role="alert"` di sini: ia sudah dirujuk `aria-describedby`, dan
   * ringkasan galat di atas form-lah yang mengumumkan (`Alert`). Ini pola DESIGN §7 — fokus
   * dipindah ke field salah pertama, sehingga deskripsinya benar-benar dibacakan.
   *
   * Bintang wajib memakai `&#160;`: kompilator Svelte memangkas spasi ASCII di tepi elemen, dan
   * spasi tak-putus juga menjaga penanda wajib tidak terpisah dari labelnya saat baris membungkus.
   */
  import type { Snippet } from "svelte";

  /** Nilai yang harus dipasang pemakai pada kontrol di dalam `children`. */
  interface FieldControl {
    id: string;
    describedby: string | undefined;
    invalid: boolean | undefined;
    required: boolean;
  }

  interface Props {
    label: string;
    id: string;
    error?: string;
    hint?: string;
    required?: boolean;
    children: Snippet<[FieldControl]>;
  }

  let { label, id, error = "", hint = "", required = false, children }: Props = $props();

  const errorId = $derived(`${id}-error`);
  const hintId = $derived(`${id}-hint`);

  /* Urutan id mengikuti urutan baca yang diinginkan: hint dulu, lalu galat. */
  const describedby = $derived(
    [hint === "" ? undefined : hintId, error === "" ? undefined : errorId]
      .filter((value): value is string => value !== undefined)
      .join(" ") || undefined,
  );

  const control: FieldControl = $derived({
    id,
    describedby,
    invalid: error === "" ? undefined : true,
    required,
  });
</script>

<div class="kran-field">
  <label class="kran-label" for={id}>
    {label}{#if required}<span aria-hidden="true">&#160;*</span>{/if}
  </label>

  {#if hint !== ""}
    <p class="kran-muted" id={hintId}>{hint}</p>
  {/if}

  {@render children(control)}

  {#if error !== ""}
    <p class="kran-alert" id={errorId}>{error}</p>
  {/if}
</div>
