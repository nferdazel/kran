<script lang="ts">
  /**
   * Nominal uang (T-236): kontrol `Input` T-286 dengan papan ketik desimal dan nama aksesibel yang
   * menyebut mata uang sekali, mis. "Nominal (IDR)".
   *
   * Batas yang disengaja:
   * - Nilai mentah tidak diubah per ketukan. Pemisah ribuan dilarang oleh kontrak a11y
   *   (`docs/design/04-a11y-and-copy.md:26`), dan `parseMoneyInput` (`@kran/ui/money`) tetap
   *   satu-satunya parser, dipanggil pemanggil saat submit. Kontrol ini tidak mem-parse, tidak
   *   membulatkan, dan tidak menyentuh `Number`.
   * - Tidak ada live region: galat hanya tampil setelah submit, lalu dibacakan lewat
   *   `aria-describedby` saat fokus pindah ke kontrol. Tidak ada pengumuman per ketukan.
   *
   * `inputmode` dan `type` dikunci di sini; atribut native lain diteruskan ke `Input`.
   */
  import type { HTMLInputAttributes } from "svelte/elements";

  import Input from "./Input.svelte";

  interface Props
    extends Omit<HTMLInputAttributes, "id" | "class" | "type" | "value" | "children" | "inputmode"> {
    label: string;
    value?: string;
    hint?: string;
    error?: string;
    required?: boolean;
    element?: HTMLInputElement | null;
    class?: string;
  }

  let {
    label,
    value = $bindable(""),
    hint = "",
    error = "",
    required = false,
    autocomplete = "off",
    element = $bindable(),
    class: extraClass = "",
    ...rest
  }: Props = $props();
</script>

<Input
  {...rest}
  {label}
  bind:value
  {hint}
  {error}
  {required}
  bind:element
  type="text"
  inputmode="decimal"
  {autocomplete}
  class={extraClass}
/>
