<script lang="ts">
  /**
   * Workspace sidebar: brand, grouped navigation, user footer (SPEC section 2).
   *
   * Data arrives already filtered for permissions and already resolved by the app (`nav.ts`), so
   * this component never duplicates the permission rule or re-resolves a path.
   */
  import type { Snippet } from "svelte";

  import NavGroup from "./NavGroup.svelte";
  import NavItem from "./NavItem.svelte";

  export interface SidebarLink {
    readonly href: string;
    readonly label: string;
    readonly current: boolean;
  }

  export interface SidebarGroup {
    readonly id: string;
    readonly label: string;
    readonly links: readonly SidebarLink[];
  }

  interface Props {
    groups: readonly SidebarGroup[];
    navLabel: string;
    title?: string;
    subtitle?: string;
    footer?: Snippet;
    onNavigate?: () => void;
  }

  let { groups, navLabel, title, subtitle, footer, onNavigate }: Props = $props();
</script>

{#if title}
  <div class="sidebar__brand">
    <strong class="sidebar__title">{title}</strong>
    {#if subtitle}<span class="sidebar__subtitle">{subtitle}</span>{/if}
  </div>
{/if}

<nav class="sidebar__nav" aria-label={navLabel}>
  {#each groups as group (group.id)}
    <NavGroup id={group.id} label={group.label}>
      {#each group.links as link (link.href)}
        <li>
          <NavItem href={link.href} label={link.label} current={link.current} {onNavigate} />
        </li>
      {/each}
    </NavGroup>
  {/each}
</nav>

{#if footer}
  <div class="sidebar__footer">{@render footer()}</div>
{/if}

<style>
  .sidebar__brand {
    display: flex;
    flex-direction: column;
    gap: 2px;
    padding-inline: var(--space-3);
    padding-block-end: var(--space-3);
    border-block-end: 1px solid var(--color-hairline);
  }

  .sidebar__title {
    font-size: var(--text-md);
    font-weight: 600;
    line-height: 1.2;
  }

  .sidebar__subtitle {
    color: var(--color-text-muted);
    font-size: var(--text-2xs);
    font-weight: 500;
  }

  .sidebar__nav {
    display: flex;
    flex: 1;
    flex-direction: column;
    gap: var(--space-4);
    overflow-y: auto;
  }

  .sidebar__footer {
    display: flex;
    flex-direction: column;
    gap: var(--space-2);
    padding-block-start: var(--space-3);
    border-block-start: 1px solid var(--color-hairline);
  }
</style>
