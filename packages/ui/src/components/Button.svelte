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

  type ButtonVariant = "primary" | "secondary" | "quiet" | "row" | "destructive";
  type ButtonType = "button" | "submit" | "reset";
  /** `sm` 32 (toolbar, baris tabel), `md` 40 (field dan aksi utama). */
  type ButtonSize = "sm" | "md";

  interface Props extends Omit<HTMLButtonAttributes, "class" | "type" | "disabled" | "children"> {
    variant?: ButtonVariant;
    size?: ButtonSize;
    type?: ButtonType;
    disabled?: boolean;
    loading?: boolean;
    class?: string;
    children: Snippet;
  }

  let {
    variant = "secondary",
    size,
    type = "button",
    disabled = false,
    loading = false,
    class: extraClass = "",
    children,
    ...rest
  }: Props = $props();

  /* `secondary` adalah tampilan dasar `.kran-button`; modifier lain menumpuk di atasnya.
   * Tinggi bawaan 40 px ada di aturan dasar; `--sm`/`--md` hanya menambah kelas saat pemanggil
   * meminta ukuran eksplisit, supaya kelas yang sudah dipakai layar tidak berubah. */
  const VARIANT_CLASS: Record<ButtonVariant, string> = {
    primary: "kran-button kran-button--primary",
    secondary: "kran-button",
    quiet: "kran-button kran-button--quiet",
    row: "kran-button kran-button--row",
    destructive: "kran-button kran-button--destructive",
  };

  const SIZE_CLASS: Record<ButtonSize, string> = {
    sm: "kran-button--sm",
    md: "kran-button--md",
  };

  const buttonClass = $derived(
    [VARIANT_CLASS[variant], size === undefined ? "" : SIZE_CLASS[size], extraClass]
      .filter(Boolean)
      .join(" "),
  );
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
