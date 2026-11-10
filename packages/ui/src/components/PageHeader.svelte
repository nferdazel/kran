<script lang="ts">
  /**
   * Page header: one `h1`, a short intro, optional meta line and at most one action (SPEC section 2).
   * It always precedes a table or form inside the shell, so the page has a single top-level title.
   */
  import type { Snippet } from "svelte";

  interface Props {
    title: string;
    intro?: string;
    meta?: Snippet;
    actions?: Snippet;
  }

  let { title, intro, meta, actions }: Props = $props();
</script>

<header class="page-header">
  <div class="page-header__text">
    <h1>{title}</h1>
    {#if intro}<p class="page-header__intro">{intro}</p>{/if}
    {#if meta}<div class="page-header__meta">{@render meta()}</div>{/if}
  </div>
  {#if actions}
    <div class="page-header__actions">{@render actions()}</div>
  {/if}
</header>

<style>
  .page-header {
    display: flex;
    align-items: flex-end;
    justify-content: space-between;
    gap: var(--space-4);
    margin-block-end: var(--space-4);
  }

  .page-header__text {
    display: flex;
    flex-direction: column;
    gap: var(--space-1);
    min-inline-size: 0;
  }

  h1 {
    font-size: var(--text-xl);
    font-weight: 600;
    letter-spacing: -0.01em;
    line-height: var(--line-height-tight);
  }

  /* Long intros stay readable instead of stretching across a 1520px canvas. */
  .page-header__intro {
    max-inline-size: 60ch;
    color: var(--color-text-2);
    font-size: var(--text-base);
  }

  .page-header__meta {
    color: var(--color-text-muted);
    font-size: var(--text-sm);
  }

  .page-header__actions {
    display: flex;
    flex: none;
    gap: var(--space-2);
  }
</style>
