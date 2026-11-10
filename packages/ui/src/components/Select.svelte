<script lang="ts">
  /**
   * Pilihan berlabel (T-286). Tetap `<select>` native - bukan `div` dengan `role="listbox"` - karena
   * itu yang menjaga perilaku keyboard dan pemilih native di ponsel tetap benar.
   *
   * Halaman mengirim `label`/`hint`/`error` dan mengisi opsi lewat children; komponen yang membuat
   * `id`, `for` dan `aria-describedby`. `bind:element` disediakan untuk layar yang perlu memindahkan
   * fokus ke kontrol ini setelah galat (mis. form buka rekening).
   */
  import type { Snippet } from "svelte";
  import type { HTMLSelectAttributes } from "svelte/elements";

  import { fieldWiring } from "./field-wiring";

  interface Props
    extends Omit<HTMLSelectAttributes, "id" | "class" | "value" | "children"> {
    label: string;
    value?: string | number;
    hint?: string;
    error?: string;
    required?: boolean;
    element?: HTMLSelectElement | null;
    class?: string;
    children: Snippet;
  }

  let {
    label,
    value = $bindable<string | number>(""),
    hint = "",
    error = "",
    required = false,
    element = $bindable(),
    class: extraClass = "",
    children,
    ...rest
  }: Props = $props();

  const id = $props.id();
  const wiring = $derived(fieldWiring(id, hint, error));

  const selectClass = $derived(["kran-control", extraClass].filter(Boolean).join(" "));
</script>

<div class="kran-field">
  <label class="kran-label" for={id}>
    {label}{#if required}<span class="kran-required" aria-hidden="true">*</span>{/if}
  </label>

  {#if hint !== ""}
    <p class="kran-muted" id={wiring.hintId}>{hint}</p>
  {/if}

  <select
    {...rest}
    {id}
    class={selectClass}
    bind:this={element}
    bind:value
    aria-describedby={wiring.describedby}
    aria-invalid={wiring.invalid}
    required={required}
  >
    {@render children()}
  </select>

  {#if error !== ""}
    <p class="kran-alert" id={wiring.errorId}>{error}</p>
  {/if}
</div>
