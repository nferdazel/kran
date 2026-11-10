<script lang="ts">
  /**
   * One sidebar destination (SPEC section 2).
   *
   * Presentational and router-agnostic: `href` is a plain string, so the web app keeps passing
   * SvelteKit-resolved paths (T-125) and the component stays usable outside it. The active item is
   * a filled chip plus `aria-current="page"`, never coloured text alone.
   */
  interface Props {
    href: string;
    label: string;
    current?: boolean;
    onNavigate?: () => void;
  }

  let { href, label, current = false, onNavigate }: Props = $props();
</script>

<a
  class="nav-item"
  {href}
  aria-current={current ? "page" : undefined}
  onclick={() => onNavigate?.()}
>
  <span class="nav-item__label">{label}</span>
</a>

<style>
  .nav-item {
    display: flex;
    align-items: center;
    min-block-size: var(--row-height);
    padding-block: var(--space-1);
    padding-inline: var(--space-3);
    border: 1px solid transparent;
    border-radius: var(--radius-sm);
    color: var(--color-text-2);
    font-size: var(--text-base);
    text-decoration: none;
  }

  .nav-item:hover {
    background: var(--color-surface-2);
    color: var(--color-text);
  }

  .nav-item[aria-current="page"] {
    background: var(--color-surface);
    border-color: var(--color-border);
    color: var(--color-text);
    font-weight: 600;
  }

  /* Long labels wrap instead of widening the off-canvas panel. */
  .nav-item__label {
    overflow-wrap: anywhere;
  }
</style>
