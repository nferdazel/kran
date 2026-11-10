<script lang="ts">
  /**
   * Teks pendek berlabel (T-286). Label, hint dan galat dimiliki kontrol ini: halaman cukup
   * mengirim teksnya, tidak pernah memasang `id`, `for` atau `aria-describedby` sendiri.
   *
   * Seluruh atribut native lain (`name`, `autocomplete`, `inputmode`, `oninput`, …) diteruskan ke
   * `<input>` asli. Kontrol tetap elemen semantik, bukan `div` dengan peran buatan.
   *
   * Bintang wajib didahului spasi tak-putus (`\u00A0`): kompilator Svelte memangkas spasi ASCII di
   * tepi elemen, dan spasi tak-putus menjaga penanda wajib tidak terpisah dari labelnya saat baris
   * membungkus.
   */
  import type { HTMLInputAttributes } from "svelte/elements";

  import { fieldWiring } from "./field-wiring";

  type InputType = "text" | "search" | "tel" | "url" | "email" | "password" | "number" | "date";

  interface Props
    extends Omit<HTMLInputAttributes, "id" | "class" | "type" | "value" | "children"> {
    label: string;
    value?: string;
    hint?: string;
    error?: string;
    required?: boolean;
    type?: InputType;
    element?: HTMLInputElement | null;
    class?: string;
  }

  let {
    label,
    value = $bindable(""),
    hint = "",
    error = "",
    required = false,
    type = "text",
    element = $bindable(),
    class: extraClass = "",
    ...rest
  }: Props = $props();

  const id = $props.id();
  const wiring = $derived(fieldWiring(id, hint, error));

  const inputClass = $derived(["kran-control", extraClass].filter(Boolean).join(" "));
</script>

<div class="kran-field">
  <label class="kran-label" for={id}>
    {label}{#if required}<span class="kran-required" aria-hidden="true">*</span>{/if}
  </label>

  {#if hint !== ""}
    <p class="kran-muted" id={wiring.hintId}>{hint}</p>
  {/if}

  <input
    {...rest}
    {id}
    bind:this={element}
    {type}
    class={inputClass}
    bind:value
    aria-describedby={wiring.describedby}
    aria-invalid={wiring.invalid}
    required={required}
  />

  {#if error !== ""}
    <p class="kran-alert" id={wiring.errorId}>{error}</p>
  {/if}
</div>
