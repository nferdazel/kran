<script lang="ts">
  /**
   * Kotak centang berlabel (T-286). Kontrolnya tetap `<input type="checkbox">` asli; kotak 16 px
   * (ukuran bawaan), sedangkan area klik/baris naik ke 40 px lewat CSS supaya tidak jadi target
   * kecil di layar sentuh.
   *
   * Label dirender setelah kontrol agar kotak berada di kiri teks; `for` menunjuk id yang dibuat
   * komponen ini, jadi halaman tidak pernah memasang id sendiri.
   */
  import type { HTMLInputAttributes } from "svelte/elements";

  import { fieldWiring } from "./field-wiring";

  interface Props
    extends Omit<HTMLInputAttributes, "id" | "class" | "type" | "checked" | "children"> {
    label: string;
    checked?: boolean;
    hint?: string;
    error?: string;
    required?: boolean;
    element?: HTMLInputElement | null;
    class?: string;
  }

  let {
    label,
    checked = $bindable(false),
    hint = "",
    error = "",
    required = false,
    element = $bindable(),
    class: extraClass = "",
    ...rest
  }: Props = $props();

  const id = $props.id();
  const wiring = $derived(fieldWiring(id, hint, error));

  const rowClass = $derived(["kran-checkbox", extraClass].filter(Boolean).join(" "));
</script>

<div class="kran-field">
  <div class={rowClass}>
    <input
      {...rest}
      {id}
      type="checkbox"
      class="kran-checkbox__box"
      bind:this={element}
      bind:checked
      aria-describedby={wiring.describedby}
      aria-invalid={wiring.invalid}
      required={required}
    />
    <label class="kran-label" for={id}>
      {label}{#if required}<span class="kran-required" aria-hidden="true">*</span>{/if}
    </label>
  </div>

  {#if hint !== ""}
    <p class="kran-muted" id={wiring.hintId}>{hint}</p>
  {/if}

  {#if error !== ""}
    <p class="kran-alert" id={wiring.errorId}>{error}</p>
  {/if}
</div>
