<script lang="ts">
  /**
   * Workspace shell for every `/app/*` route (T-285, SPEC section 2, D-202).
   *
   * Thin wrapper: all layout lives in `@kran/ui` components, this file only supplies data and
   * labels. The command palette from T-110 stays here, unchanged in behaviour (Ctrl+K, native
   * `<dialog>`, focus trap), because it is a route-level concern rather than shell chrome.
   *
   * Decisions kept from T-110:
   *  - **Actions are navigation**, sourced from the same `nav.ts` as the menu; no action mutates
   *    data and no permission rule is copied into the UI (spec §13).
   *  - Native `<dialog>` + `showModal()`; the focus trap is written out explicitly so it does not
   *    depend on the browser version.
   *  - `Ctrl+K`/`Cmd+K` everywhere **except** while a text field has focus.
   */
  import { tick } from "svelte";
  import { goto } from "$app/navigation";
  import { resolve } from "$app/paths";
  import { page } from "$app/state";

  import * as m from "#lib/paraglide/messages.js";
  import { currentLocale, supportedLocales } from "#lib/app/i18n.js";
  import { formatDate } from "#lib/app/format.js";
  import {
    appNavLinks,
    groupVisibleLinks,
    isActiveHref,
    sessionPermissions,
    visibleNavLinks,
  } from "#lib/app/nav.js";
  import { filterActions, paletteActions } from "#lib/app/palette.js";
  import { api } from "#lib/app/api.js";

  import AppShell from "@kran/ui/components/AppShell.svelte";
  import Sidebar, { type SidebarGroup } from "@kran/ui/components/Sidebar.svelte";
  import Topbar from "@kran/ui/components/Topbar.svelte";

  let { children } = $props();

  /**
   * Menu is filtered per permission (spec §13). `page.data` merges every `load` of this route, so
   * `session` from `routes/app/+layout.ts` is available; while it is missing, permissions count as
   * empty and protected links stay hidden (fail-closed).
   */
  const navLinks = $derived(visibleNavLinks(appNavLinks, sessionPermissions(page.data.session)));
  const sidebarGroups = $derived<SidebarGroup[]>(
    groupVisibleLinks(navLinks).map((group) => ({
      id: group.id,
      label: group.label(),
      links: group.links.map((link) => ({
        href: link.href,
        label: link.label(),
        current: isActiveHref(page.url.pathname, link.href),
      })),
    })),
  );

  /** Breadcrumb = product + current destination; a leaf without a menu entry keeps only the root. */
  const breadcrumb = $derived(
    (() => {
      const current = navLinks.find((link) => isActiveHref(page.url.pathname, link.href));
      return current === undefined
        ? [{ label: m.common_app_title() }]
        : [{ label: m.common_app_title() }, { label: current.label() }];
    })(),
  );

  const sessionName = $derived(
    (page.data.session as { fullName?: string } | undefined)?.fullName ?? "",
  );

  /**
   * Business date indicator (spec section 14.3). Three honest states, kept from the pre-v2 shell:
   * `undefined` = read failed (render nothing), `null` = institution has no business date row yet,
   * `string` = a real date. The value is formatted here so `@kran/ui` stays locale-free.
   */
  const businessDateText = $derived(
    (() => {
      const value = page.data.businessDate as string | null | undefined;
      if (value === undefined) return undefined;
      return value === null ? m.common_business_date_unknown() : formatDate(value);
    })(),
  );

  async function logout(): Promise<void> {
    try {
      await api.POST("/api/v1/auth/logout");
    } catch {
      // A dead session must still take the user off this screen: a network failure cannot make
      // "Sign out" look broken.
    }
    await goto(resolve("/login"));
  }

  let open = $state(false);
  let query = $state("");
  // Elements are looked up by id, not `bind:this`: on this route the binding is not attached when
  // the window handler is active, so showModal/focus never ran.
  function dialogElement(): HTMLDialogElement | null {
    return document.getElementById("palette-dialog") as HTMLDialogElement | null;
  }
  function inputElement(): HTMLInputElement | null {
    return document.getElementById("palette-search") as HTMLInputElement | null;
  }
  function listElement(): HTMLUListElement | null {
    return document.getElementById("palette-list") as HTMLUListElement | null;
  }
  /** Focus holder before the palette opened; restored on close (spec §17.1). */
  let restoreFocusTo: HTMLElement | null = null;

  // Actions = the permission-filtered nav, so the palette never offers a destination the server
  // would reject (spec §13). Language is read at mount: switching it rebuilds the `/app` subtree
  // (`{#key locale}` in the root layout), so this component never sees a stale locale.
  const actions = $derived(
    paletteActions(
      visibleNavLinks(appNavLinks, sessionPermissions(page.data.session)),
      currentLocale(),
      supportedLocales,
    ),
  );
  const matches = $derived(filterActions(actions, query));

  /** Text entry: that is where Ctrl+K belongs to the field, not the palette. */
  function isTextEntry(target: EventTarget | null): boolean {
    if (target instanceof HTMLTextAreaElement) return true;
    if (!(target instanceof HTMLInputElement)) {
      return target instanceof HTMLElement && target.isContentEditable;
    }
    return !["button", "checkbox", "radio", "submit", "reset", "range", "file", "color"].includes(
      target.type,
    );
  }

  function optionElements(): HTMLElement[] {
    const list = listElement();
    return list === null ? [] : [...list.querySelectorAll<HTMLElement>("a[href]")];
  }

  async function openPalette(): Promise<void> {
    if (open) return;
    restoreFocusTo = document.activeElement instanceof HTMLElement ? document.activeElement : null;
    query = "";
    open = true;
    await tick();
    const dialog = dialogElement();
    if (dialog !== null && !dialog.open) dialog.showModal();
    inputElement()?.focus();
  }

  function closePalette(): void {
    dialogElement()?.close();
  }

  /** `close` comes from Esc, an action click, or `closePalette()` — one focus-restore path. */
  function onDialogClose(): void {
    open = false;
    query = "";
    const target = restoreFocusTo;
    restoreFocusTo = null;
    if (target !== null && target.isConnected) target.focus();
  }

  function onWindowKeydown(event: KeyboardEvent): void {
    if (!(event.ctrlKey || event.metaKey) || event.altKey || event.shiftKey) return;
    if (event.key.toLowerCase() !== "k" || open) return;
    if (isTextEntry(event.target)) return;
    event.preventDefault();
    void openPalette();
  }

  /** Tab wraps inside the palette: `input` ↔ last action. */
  function trapTab(event: KeyboardEvent): void {
    const focusables = [inputElement(), ...optionElements()].filter(
      (element): element is HTMLElement => element !== null,
    );
    const first = focusables[0];
    const last = focusables[focusables.length - 1];
    if (first === undefined || last === undefined) return;
    const active = document.activeElement;
    if (event.shiftKey) {
      const dialog = dialogElement();
      const inside = active instanceof Node && dialog !== null && dialog.contains(active);
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

  /** Arrows from input and from actions; from the input, down goes to the first action. */
  function moveFocus(delta: number): void {
    const options = optionElements();
    if (options.length === 0) return;
    const current = options.indexOf(document.activeElement as HTMLElement);
    const next =
      current === -1
        ? delta > 0
          ? 0
          : options.length - 1
        : (current + delta + options.length) % options.length;
    options[next]?.focus();
  }

  function onDialogKeydown(event: KeyboardEvent): void {
    // While the modal is open the page behind is inert: page shortcuts must not react to typing.
    event.stopPropagation();
    if (event.key === "Escape") {
      event.preventDefault();
      closePalette();
      return;
    }
    if (event.key === "Tab") {
      trapTab(event);
      return;
    }
    if (event.key === "ArrowDown" || event.key === "ArrowUp") {
      event.preventDefault();
      moveFocus(event.key === "ArrowDown" ? 1 : -1);
      return;
    }
    if (event.key === "Enter" && event.target === inputElement()) {
      event.preventDefault();
      optionElements()[0]?.click();
    }
  }
</script>

<svelte:window onkeydown={onWindowKeydown} />

<AppShell skipLabel={m.common_skip_to_content()} panelLabel={m.common_sidebar_label()}>
  {#snippet sidebar({ close })}
    <Sidebar
      groups={sidebarGroups}
      navLabel={m.common_nav_label()}
      title={m.common_brand_short()}
      subtitle={m.app_sidebar_subtitle()}
      onNavigate={close}
    >
      {#snippet footer()}
        {#if sessionName !== ""}
          <p class="sidebar-user">{m.app_signed_in_as({ name: sessionName })}</p>
        {/if}
        <a class="sidebar-action" href={resolve("/app/password")}>{m.app_change_password()}</a>
        <button class="sidebar-action" type="button" onclick={logout}>{m.app_logout()}</button>
      {/snippet}
    </Sidebar>
  {/snippet}

  {#snippet topbar({ menuOpen, toggleMenu, sidebarId })}
    <Topbar
      breadcrumb={breadcrumb}
      menuLabel={m.common_menu_toggle()}
      breadcrumbLabel={m.common_breadcrumb_label()}
      businessDate={businessDateText}
      businessDateLabel={m.common_business_date_label()}
      {menuOpen}
      {sidebarId}
      onMenuToggle={toggleMenu}
    />
  {/snippet}

  {@render children()}
</AppShell>

<dialog
  id="palette-dialog"
  class="kran-palette"
  aria-labelledby="palette-heading"
  onkeydown={onDialogKeydown}
  onclose={onDialogClose}
>
  <h2 class="kran-palette__heading" id="palette-heading">{m.palette_heading()}</h2>

  <div class="kran-field">
    <label class="kran-label" for="palette-search">{m.palette_search_label()}</label>
    <input
      class="kran-input"
      id="palette-search"
      type="search"
      bind:value={query}
      autocomplete="off"
      spellcheck="false"
      aria-describedby="palette-hint"
    />
  </div>

  {#if matches.length === 0}
    <p class="kran-palette__empty kran-muted" role="status">{m.palette_empty()}</p>
  {:else}
    <ul class="kran-palette__list" id="palette-list">
      {#each matches as action (action.href)}
        <li>
          <a class="kran-palette__option" href={action.href} onclick={closePalette}>
            {action.label}
          </a>
        </li>
      {/each}
    </ul>
  {/if}

  <p class="kran-palette__hint kran-muted" id="palette-hint">{m.palette_hint()}</p>
</dialog>

<style>
  .sidebar-user {
    color: var(--color-text-muted);
    font-size: var(--text-sm);
    overflow-wrap: anywhere;
  }

  .sidebar-action {
    display: flex;
    align-items: center;
    min-block-size: var(--control-height);
    padding-inline: var(--space-3);
    border: 1px solid transparent;
    border-radius: var(--radius-sm);
    background: transparent;
    color: var(--color-text-2);
    font: inherit;
    font-size: var(--text-base);
    text-align: start;
    text-decoration: none;
    cursor: pointer;
  }

  .sidebar-action:hover {
    background: var(--color-surface-2);
    color: var(--color-text);
  }
</style>
