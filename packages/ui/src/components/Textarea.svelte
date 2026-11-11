<script lang="ts">
  /**
   * Teks panjang berlabel (T-286). Sama dengan `Input` - label, hint, galat dan id dimiliki
   * komponen - hanya elemennya `<textarea>`. Dipisah supaya `Input` tetap berarti satu elemen.
   */
  import type { HTMLTextareaAttributes } from "svelte/elements";

  import { fieldWiring } from "./field-wiring";

  interface Props
    extends Omit<HTMLTextareaAttributes, "id" | "class" | "value" | "children"> {
    label: string;
    value?: string;
    hint?: string;
    error?: string;
    required?: boolean;
    element?: HTMLTextAreaElement | null;
    class?: string;
  }

  let {
    label,
    value = $bindable(""),
    hint = "",
    error = "",
    required = false,
    element = $bindable(),
    class: extraClass = "",
    ...rest
  }: Props = $props();

  const id = $props.id();
  const wiring = $derived(fieldWiring(id, hint, error));

  const textareaClass = $derived(["kran-control", extraClass].filter(Boolean).join(" "));
</script>

<div class="kran-field">
  <label class="kran-label" for={id}>
    {label}{#if required}<span class="kran-required" aria-hidden="true">*</span>{/if}
  </label>

  {#if hint !== ""}
    <p class="kran-muted" id={wiring.hintId}>{hint}</p>
  {/if}

  <textarea
    {...rest}
    {id}
    bind:this={element}
    class={textareaClass}
    bind:value
    aria-describedby={wiring.describedby}
    aria-invalid={wiring.invalid}
    required={required}
  ></textarea>

  {#if error !== ""}
    <p class="kran-alert" id={wiring.errorId}>{error}</p>
  {/if}
</div>
