<script lang="ts">
  /**
   * Application shell: skip link, sidebar panel, topbar, `#main` (SPEC section 2, D-202).
   *
   * The layout composes it with snippets so this package stays router- and i18n-free: every label
   * arrives as a prop from the app's message catalog.
   *
   * Below 1024px the panel is off-canvas. It is pulled out with `visibility: hidden` (not just a
   * transform), so its links leave the tab order and the accessibility tree while closed; opening
   * it moves focus inside, Tab wraps, Escape closes and returns focus to the menu button.
   */
  import { onMount, type Snippet } from "svelte";

  interface PanelApi {
    close: () => void;
  }

  interface TopbarApi {
    menuOpen: boolean;
    toggleMenu: () => void;
    closeMenu: () => void;
    sidebarId: string;
  }

  interface Props {
    skipLabel: string;
    /** Accessible name for the sidebar panel landmark (T-285 gate fix). */
    panelLabel?: string;
    sidebarId?: string;
    sidebar: Snippet<[PanelApi]>;
    topbar: Snippet<[TopbarApi]>;
    children: Snippet;
  }

  let {
    skipLabel,
    panelLabel,
    sidebarId = "app-sidebar",
    sidebar,
    topbar,
    children,
  }: Props = $props();

  let menuOpen = $state(false);
  let isMobile = $state(false);

  onMount(() => {
    const query = window.matchMedia("(max-width: 1023px)");
    isMobile = query.matches;
    const onChange = (event: MediaQueryListEvent) => {
      isMobile = event.matches;
      if (!event.matches) menuOpen = false;
    };
    query.addEventListener("change", onChange);
    return () => query.removeEventListener("change", onChange);
  });

  /** Focus targets inside the panel, in tab order; hidden elements are filtered out. */
  function panelFocusables(): HTMLElement[] {
    const panel = document.getElementById(sidebarId);
    if (panel === null) return [];
    return [
      ...panel.querySelectorAll<HTMLElement>(
        'a[href], button:not([disabled]), input:not([disabled]), select:not([disabled]), textarea:not([disabled]), [tabindex]:not([tabindex="-1"])',
      ),
    ].filter((element) => element.offsetParent !== null);
  }

  function menuButton(): HTMLElement | null {
    return document.querySelector<HTMLElement>("[data-shell-menu-button]");
  }

  function toggleMenu(): void {
    menuOpen = !menuOpen;
    if (menuOpen) queueMicrotask(() => panelFocusables()[0]?.focus());
  }

  function closeMenu(): void {
    if (!menuOpen) return;
    menuOpen = false;
    menuButton()?.focus();
  }

  /**
   * Open panel keyboard handling lives on `window`: the panel is a navigation region, not a
   * dialog, so it must not claim a dialog role just to receive this.
   */
  function onWindowKeydown(event: KeyboardEvent): void {
    if (!menuOpen || !isMobile) return;
    if (event.key === "Escape") {
      event.preventDefault();
      closeMenu();
      return;
    }
    if (event.key !== "Tab") return;
    const focusables = panelFocusables();
    const first = focusables[0];
    const last = focusables[focusables.length - 1];
    if (first === undefined || last === undefined) return;
    const active = document.activeElement;
    const inside = active instanceof Node && document.getElementById(sidebarId)?.contains(active);
    if (event.shiftKey) {
      if (!inside || active === first) {
        event.preventDefault();
        last.focus();
      }
      return;
    }
    if (active === last) {
      event.preventDefault();
      first.focus();
    }
  }
</script>

<svelte:window onkeydown={onWindowKeydown} />

<a class="shell-skip" href="#main">{skipLabel}</a>

<div class="shell" class:shell--menu-open={menuOpen}>
  <aside class="shell__panel" id={sidebarId} aria-label={panelLabel}>
    {@render sidebar({ close: closeMenu })}
  </aside>

  {#if menuOpen && isMobile}
    <div class="shell__scrim" aria-hidden="true"></div>
  {/if}

  <div class="shell__column">
    {@render topbar({ menuOpen, toggleMenu, closeMenu, sidebarId })}
    <main id="main" class="shell__main" tabindex="-1">
      {@render children()}
    </main>
  </div>
</div>

<style>
  /* Same hide-until-focused contract as `.kran-skip-link`, scoped to the shell. */
  .shell-skip {
    position: absolute;
    inset-block-start: var(--space-2);
    inset-inline-start: var(--space-2);
    z-index: 100;
    padding-block: var(--space-2);
    padding-inline: var(--space-4);
    border-radius: var(--radius-sm);
    background: var(--color-primary);
    color: var(--color-text-on-primary);
    text-decoration: none;
    transform: translateY(-200%);
  }

  .shell-skip:focus-visible {
    transform: none;
  }

  .shell {
    display: grid;
    grid-template-columns: var(--sidebar-width) minmax(0, 1fr);
    min-block-size: 100vh;
    background: var(--color-bg);
  }

  .shell__panel {
    display: flex;
    flex-direction: column;
    gap: var(--space-4);
    min-block-size: 100%;
    padding: var(--space-4) var(--space-3);
    background: var(--color-side);
    border-inline-end: 1px solid var(--color-hairline);
  }

  .shell__column {
    display: flex;
    flex-direction: column;
    min-inline-size: 0;
  }

  .shell__main {
    flex: 1;
    inline-size: 100%;
    max-inline-size: var(--layout-max-width);
    min-inline-size: 0;
    padding: var(--content-pad);
  }

  @media (max-width: 1023px) {
    .shell {
      grid-template-columns: minmax(0, 1fr);
    }

    .shell__panel {
      position: fixed;
      inset-block: 0;
      inset-inline-start: 0;
      z-index: 50;
      inline-size: var(--sidebar-width);
      max-inline-size: 85vw;
      overflow-y: auto;
      box-shadow: var(--shadow-2);
      transform: translateX(-100%);
      visibility: hidden;
      transition: transform var(--motion-duration-base) var(--motion-ease);
    }

    .shell--menu-open .shell__panel {
      transform: none;
      visibility: visible;
    }

    .shell__scrim {
      position: fixed;
      inset: 0;
      z-index: 40;
      background: rgb(14 16 19 / 0.32);
    }
  }

  @media (prefers-reduced-motion: reduce) {
    .shell__panel {
      transition: none;
    }
  }
</style>
