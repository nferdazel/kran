<script lang="ts">
  /**
   * Row of screen controls under the page header (SPEC section 2): 32px actions, 40px fields.
   * `search` turns the row into a search landmark, which is what filtering actually is.
   */
  import type { Snippet } from "svelte";

  interface Props {
    label?: string;
    search?: boolean;
    children: Snippet;
  }

  let { label, search = false, children }: Props = $props();
</script>

<div class="toolbar" role={search ? "search" : undefined} aria-label={label}>
  {@render children()}
</div>

<style>
  .toolbar {
    display: flex;
    flex-wrap: wrap;
    align-items: center;
    gap: var(--space-2);
    min-block-size: var(--toolbar-height);
    margin-block-end: var(--space-3);
  }

  /* Toolbar actions are 32px; a control that needs 40 is a form field, not a toolbar action. */
  .toolbar > :global(button),
  .toolbar > :global(.kran-button) {
    min-block-size: var(--control-height);
  }
</style>
