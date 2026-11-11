<script lang="ts">
  /**
   * Labelled navigation group (SPEC section 2). The label is a `<p>` with `id`, not a heading: the
   * sidebar sits before the page `<h1>`, so a heading here would start the document at level 2.
   */
  import type { Snippet } from "svelte";

  interface Props {
    id: string;
    label: string;
    children: Snippet;
  }

  let { id, label, children }: Props = $props();

  const labelId = $derived(`nav-group-${id}`);
</script>

<div class="nav-group">
  <p class="nav-group__label" id={labelId}>{label}</p>
  <ul class="nav-group__list" aria-labelledby={labelId}>
    {@render children()}
  </ul>
</div>

<style>
  .nav-group {
    display: flex;
    flex-direction: column;
    gap: var(--space-1);
  }

  .nav-group__label {
    padding-inline: var(--space-3);
    color: var(--color-text-muted);
    font-size: var(--text-2xs);
    font-weight: 500;
    letter-spacing: 0.09em;
    text-transform: uppercase;
  }

  .nav-group__list {
    display: flex;
    flex-direction: column;
    gap: var(--space-1);
    margin: 0;
    padding: 0;
    list-style: none;
  }
</style>
