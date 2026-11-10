<script lang="ts">
  /**
   * Workspace topbar: menu button (below 1024px), breadcrumb, right slot (SPEC section 2).
   *
   * The menu button is rendered at every width and hidden by CSS above 1023px: keeping it in the
   * DOM means the off-canvas panel always has a control that names it (`aria-controls`) and a
   * focus target to return to after Escape.
   */
  import type { Snippet } from "svelte";

  export interface Crumb {
    readonly label: string;
    readonly href?: string;
  }

  interface Props {
    breadcrumb: readonly Crumb[];
    menuLabel: string;
    breadcrumbLabel: string;
    menuOpen: boolean;
    sidebarId: string;
    onMenuToggle: () => void;
    /**
     * Business date (spec section 14.3), already resolved and formatted by the app:
     * `undefined` = value unknown (indicator hidden), `string` = date or "not available" text.
     */
    businessDate?: string;
    businessDateLabel?: string;
    actions?: Snippet;
  }

  let {
    breadcrumb,
    menuLabel,
    breadcrumbLabel,
    menuOpen,
    sidebarId,
    onMenuToggle,
    businessDate,
    businessDateLabel = "",
    actions,
  }: Props = $props();
</script>

<header class="topbar">
  <button
    class="topbar__menu"
    type="button"
    aria-label={menuLabel}
    aria-expanded={menuOpen}
    aria-controls={sidebarId}
    onclick={onMenuToggle}
    data-shell-menu-button
  >
    <svg viewBox="0 0 16 16" width="16" height="16" aria-hidden="true" focusable="false">
      <path d="M2 4h12M2 8h12M2 12h12" stroke="currentColor" stroke-width="1.5" fill="none" />
    </svg>
  </button>

  <nav class="topbar__crumbs" aria-label={breadcrumbLabel}>
    <ol>
      {#each breadcrumb as crumb, index (crumb.label + (crumb.href ?? ""))}
        {#if index > 0}
          <li class="topbar__sep" aria-hidden="true">/</li>
        {/if}
        <li>
          {#if crumb.href}
            <a href={crumb.href}>{crumb.label}</a>
          {:else}
            <span aria-current="page">{crumb.label}</span>
          {/if}
        </li>
      {/each}
    </ol>
  </nav>

  {#if businessDate !== undefined || actions}
    <div class="topbar__meta">
      {#if businessDate !== undefined}
        <p class="kran-business-date">
          <span class="kran-status-dot" aria-hidden="true"></span>
          <span class="kran-muted">{businessDateLabel}:</span>
          <span class="kran-num">{businessDate}</span>
        </p>
      {/if}
      {#if actions}
        <div class="topbar__actions">{@render actions()}</div>
      {/if}
    </div>
  {/if}
</header>

<style>
  .topbar {
    display: flex;
    align-items: center;
    gap: var(--space-3);
    min-block-size: var(--topbar-height);
    padding-inline: var(--space-4);
    background: var(--color-surface);
    border-block-end: 1px solid var(--color-hairline);
  }

  .topbar__menu {
    display: none;
    align-items: center;
    justify-content: center;
    inline-size: var(--control-height-primary);
    block-size: var(--control-height-primary);
    margin-inline-start: calc(var(--space-2) * -1);
    border: 1px solid transparent;
    border-radius: var(--radius-sm);
    background: transparent;
    color: var(--color-text);
    cursor: pointer;
  }

  .topbar__menu:hover {
    background: var(--color-surface-2);
  }

  @media (max-width: 1023px) {
    .topbar__menu {
      display: inline-flex;
    }
  }

  .topbar__crumbs ol {
    display: flex;
    align-items: center;
    gap: var(--space-2);
    margin: 0;
    padding: 0;
    list-style: none;
    font-size: var(--text-sm);
  }

  .topbar__crumbs a {
    color: var(--color-text-muted);
    text-decoration: none;
  }

  .topbar__crumbs a:hover {
    color: var(--color-text);
    text-decoration: underline;
  }

  .topbar__crumbs [aria-current="page"] {
    color: var(--color-text-2);
    font-weight: 500;
  }

  .topbar__sep {
    color: var(--color-text-muted);
  }

  .topbar__meta {
    display: flex;
    align-items: center;
    gap: var(--space-3);
    margin-inline-start: auto;
  }

  .topbar__actions {
    display: flex;
    align-items: center;
    gap: var(--space-2);
  }
</style>
