<script lang="ts">
  /**
   * Command palette untuk seluruh rute `/app/*` (T-110, spec §14.3 "keyboard-first").
   *
   * Keputusan yang mengikat (lihat `docs/tasks/T-110.md`):
   *  - **Aksi = navigasi**, bersumber dari `nav.ts` yang sama dengan menu; tidak ada perintah yang
   *    mengubah data dan tidak ada aturan izin yang disalin ke UI (spec §13).
   *  - `<dialog>` native + `showModal()`: elemen semantik dulu (spec §17.1), jadi peran `dialog`,
   *    `aria-modal`, lapisan teratas, dan `inert` latar datang dari platform — bukan ARIA buatan.
   *    Focus trap tetap ditulis eksplisit (Tab membungkus) supaya perilakunya pasti, bukan bergantung
   *    versi peramban.
   *  - `Ctrl+K`/`Cmd+K` global, **kecuali** saat fokus ada di field teks: di sana Ctrl+K punya
   *    arti sendiri (pengeditan, pencarian peramban) dan tidak boleh direbut.
   */
  import { tick } from "svelte";

  import * as m from "#lib/paraglide/messages.js";
  import { currentLocale, supportedLocales } from "#lib/app/i18n.js";
  import { appNavLinks } from "#lib/app/nav.js";
  import { filterActions, paletteActions } from "#lib/app/palette.js";

  let { children } = $props();

  let open = $state(false);
  let query = $state("");
  let dialogEl = $state<HTMLDialogElement | undefined>(undefined);
  let inputEl = $state<HTMLInputElement | undefined>(undefined);
  let listEl = $state<HTMLUListElement | undefined>(undefined);
  /** Elemen pemegang fokus sebelum palette dibuka; dikembalikan saat ditutup (spec §17.1). */
  let restoreFocusTo: HTMLElement | null = null;

  // Bahasa dibaca saat mount: ganti bahasa membangun ulang subtree `/app` (`{#key locale}` di
  // layout akar), jadi komponen ini tidak pernah melihat locale basi.
  const actions = paletteActions(appNavLinks, currentLocale(), supportedLocales);
  const matches = $derived(filterActions(actions, query));

  /** Tombol ketik: di sanalah Ctrl+K tidak boleh direbut palette. */
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
    if (listEl === undefined) return [];
    return [...listEl.querySelectorAll<HTMLElement>("a[href]")];
  }

  async function openPalette(): Promise<void> {
    if (open) return;
    restoreFocusTo = document.activeElement instanceof HTMLElement ? document.activeElement : null;
    query = "";
    open = true;
    await tick();
    if (dialogEl !== undefined && !dialogEl.open) dialogEl.showModal();
    inputEl?.focus();
  }

  function closePalette(): void {
    dialogEl?.close();
  }

  /** `close` datang dari Esc, klik aksi, atau `closePalette()` — satu jalur pemulihan fokus. */
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

  /** Tab membungkus di dalam palette: `input` ↔ aksi terakhir. */
  function trapTab(event: KeyboardEvent): void {
    const focusables = [inputEl, ...optionElements()].filter(
      (element): element is HTMLElement => element !== undefined,
    );
    const first = focusables[0];
    const last = focusables[focusables.length - 1];
    if (first === undefined || last === undefined) return;
    const active = document.activeElement;
    if (event.shiftKey) {
      const inside = active instanceof Node && dialogEl !== undefined && dialogEl.contains(active);
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

  /** Panah dari input maupun dari aksi; dari input turun = aksi pertama (combobox sederhana). */
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
    // Selama modal terbuka, halaman di belakang inert: pintasan halaman (Esc/F-key teller) tidak
    // boleh ikut bereaksi terhadap ketikan di dalam palette.
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
    if (event.key === "Enter" && event.target === inputEl) {
      event.preventDefault();
      optionElements()[0]?.click();
    }
  }
</script>

<svelte:window onkeydown={onWindowKeydown} />

{@render children()}

<dialog
  class="kran-palette"
  aria-modal="true"
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
      bind:this={inputEl}
      bind:value={query}
      autocomplete="off"
      spellcheck="false"
      aria-describedby="palette-hint"
    />
  </div>

  {#if matches.length === 0}
    <p class="kran-palette__empty kran-muted" role="status">{m.palette_empty()}</p>
  {:else}
    <ul class="kran-palette__list" bind:this={listEl}>
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
