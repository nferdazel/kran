<script lang="ts">
  /**
   * Tombol KRAN (DESIGN §4 kontrol 32/44 px, §7 state `:disabled` terlihat, §10 keyboard).
   *
   * Presentasional: teks datang dari `children`, tidak ada i18n di sini. Nama kelas hanya
   * meneruskan `.kran-button*` yang sudah ada di `components.css`; komponen tidak menambah
   * sistem styling kedua.
   *
   * `disabled` dirender sebagai atribut native (bukan `aria-disabled`) supaya aturan `:disabled`
   * dan `forced-colors` peramban bekerja. `loading` juga menonaktifkan tombol: satu klik pada aksi
   * finansial tidak boleh menjadi dua permintaan.
   *
   * Atribut tombol lain (`onclick`, `name`, `value`, `form`, `aria-label`, …) diteruskan apa adanya;
   * komponen yang menelan handler klik tidak bisa dipakai untuk aksi apa pun.
   */
  import type { Snippet } from "svelte";
  import type { HTMLButtonAttributes } from "svelte/elements";

  type ButtonVariant = "primary" | "secondary" | "row" | "destructive";
  type ButtonType = "button" | "submit" | "reset";

  interface Props extends Omit<HTMLButtonAttributes, "class" | "type" | "disabled" | "children"> {
    variant?: ButtonVariant;
    type?: ButtonType;
    disabled?: boolean;
    loading?: boolean;
    class?: string;
    children: Snippet;
  }

  let {
    variant = "secondary",
    type = "button",
    disabled = false,
    loading = false,
    class: extraClass = "",
    children,
    ...rest
  }: Props = $props();

  /* `secondary` adalah tampilan dasar `.kran-button`; modifier lain menumpuk di atasnya. */
  const VARIANT_CLASS: Record<ButtonVariant, string> = {
    primary: "kran-button kran-button--primary",
    secondary: "kran-button",
    row: "kran-button kran-button--row",
    destructive: "kran-button kran-button--destructive",
  };

  const buttonClass = $derived([VARIANT_CLASS[variant], extraClass].filter(Boolean).join(" "));
</script>

<button
  {...rest}
  class={buttonClass}
  {type}
  disabled={disabled || loading}
  aria-busy={loading ? "true" : undefined}
>
  {@render children()}
</button>
