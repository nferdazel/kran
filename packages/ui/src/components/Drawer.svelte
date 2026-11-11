<script module lang="ts">
  /**
   * Kontrak fokus drawer (T-290), dipisah sebagai fungsi murni supaya kedua arah Tab dan pemulihan
   * fokus bisa diuji tanpa DOM: suite `packages/ui` sengaja berjalan di `node` tanpa jsdom.
   */

  /** Elemen yang menerima fokus di dalam panel. Heading (`tabindex="-1"`) sengaja tidak ikut. */
  export const FOCUSABLE_SELECTOR =
    'a[href], button:not([disabled]), input:not([disabled]), select:not([disabled]), textarea:not([disabled]), [tabindex]:not([tabindex="-1"])';

  /**
   * Elemen yang harus difokuskan saat Tab menabrak tepi panel; `null` berarti biarkan peramban
   * memindahkan fokus seperti biasa (masih di dalam panel).
   */
  export function wrapTabTarget<T>(
    items: readonly T[],
    active: T | null,
    backwards: boolean,
  ): T | null {
    if (items.length === 0) return null;
    const first = items[0] as T;
    const last = items[items.length - 1] as T;
    const index = active === null ? -1 : items.indexOf(active);
    if (index === -1) return backwards ? last : first;
    if (backwards) return index === 0 ? last : null;
    return index === items.length - 1 ? first : null;
  }

  export interface FocusRestoreCandidate {
    isConnected?: boolean;
    disabled?: boolean;
  }

  /**
   * Pemicu asli menang atas cadangan: fokus kembali ke elemen yang membuka drawer, bukan ke
   * `body`. Cadangan hanya dipakai kalau pemicu sudah lepas dari dokumen atau dinonaktifkan.
   */
  export function restoreFocusTarget<T extends FocusRestoreCandidate>(
    trigger: T | null,
    fallback: T | null,
  ): T | null {
    if (trigger !== null && trigger.isConnected !== false && trigger.disabled !== true) {
      return trigger;
    }
    return fallback;
  }
</script>

<script lang="ts">
  /**
   * Panel samping kanan (T-290): 520 px, tinggi penuh, `--surface`, `--shadow-2`, dan 100% lebar di
   * bawah 640 px. Detail baris daftar yang tadinya menumpuk di badan layar pindah ke sini.
   *
   * `aria-modal="true"` hanya dipasang karena trap-nya benar-benar ada: Tab membungkus di kedua
   * arah, Escape menutup, dan fokus kembali ke elemen pemicu yang persis, bukan `body`. Sari
   * menemukan dua kegagalan itu di mockup; keduanya jadi acceptance, bukan saran.
   *
   * Teks seluruhnya dari pemakai (tidak ada i18n di `packages/ui`): `title` adalah heading sekaligus
   * target `aria-labelledby`, dan heading itu menerima fokus saat panel dibuka supaya pembaca layar
   * langsung menyebut konteksnya.
   *
   * Keadaan: terbuka, memuat, galat dengan coba lagi, dan konfirmasi perubahan belum disimpan saat
   * ditutup. Komponen presentasional: tidak memuat data dan tidak menyimpan keputusan tutup.
   */
  import { tick } from "svelte";
  import type { Snippet } from "svelte";

  import Button from "./Button.svelte";
  import ErrorState from "./ErrorState.svelte";
  import LoadingState from "./LoadingState.svelte";

  interface Props {
    open: boolean;
    title: string;
    onclose: () => void;
    /** Nama tombol tutup, mis. `common_close`. */
    closeLabel: string;
    /** Ada perubahan belum disimpan: menutup minta konfirmasi dulu. */
    dirty?: boolean;
    confirmTitle?: string;
    discardLabel?: string;
    keepEditingLabel?: string;
    loading?: boolean;
    loadingLabel?: string;
    error?: string;
    retryLabel?: string;
    onretry?: () => void;
    children?: Snippet;
  }

  let {
    open,
    title,
    onclose,
    closeLabel,
    dirty = false,
    confirmTitle = "",
    discardLabel = "",
    keepEditingLabel = "",
    loading = false,
    loadingLabel = "",
    error = "",
    retryLabel = "",
    onretry,
    children,
  }: Props = $props();

  const headingId = $props.id();

  let panel = $state<HTMLElement | null>(null);
  let headingElement = $state<HTMLElement | null>(null);
  let confirmElement = $state<HTMLElement | null>(null);
  let confirming = $state(false);

  /** Elemen yang membuka drawer; fokus kembali ke sini, bukan ke `body`. */
  let trigger: HTMLElement | null = null;
  let wasOpen = false;

  async function focusHeading(): Promise<void> {
    await tick();
    headingElement?.focus();
  }

  $effect(() => {
    if (open && !wasOpen) {
      wasOpen = true;
      confirming = false;
      trigger = document.activeElement instanceof HTMLElement ? document.activeElement : null;
      void focusHeading();
      return;
    }
    if (!open && wasOpen) {
      wasOpen = false;
      confirming = false;
      const target = restoreFocusTarget(trigger, document.getElementById("main"));
      trigger = null;
      target?.focus();
    }
  });

  function focusables(): HTMLElement[] {
    if (panel === null) return [];
    return [...panel.querySelectorAll<HTMLElement>(FOCUSABLE_SELECTOR)];
  }

  function requestClose(): void {
    if (dirty && !confirming) {
      confirming = true;
      void tick().then(() => confirmElement?.focus());
      return;
    }
    onclose();
  }

  function discardAndClose(): void {
    confirming = false;
    onclose();
  }

  function keepEditing(): void {
    confirming = false;
    void focusHeading();
  }

  function onKeydown(event: KeyboardEvent): void {
    if (event.key === "Escape") {
      event.preventDefault();
      requestClose();
      return;
    }
    if (event.key !== "Tab") return;
    const active = document.activeElement;
    const target = wrapTabTarget(
      focusables(),
      active instanceof HTMLElement ? active : null,
      event.shiftKey,
    );
    if (target === null) return;
    event.preventDefault();
    target.focus();
  }

  /**
   * Handler menempel di window, bukan di panel: klik scrim memindahkan fokus ke `body`, dan
   * handler yang hanya ada di panel akan ikut mati padahal `aria-modal` masih menyala. Svelte 5
   * melarang `<svelte:window>` di dalam blok, jadi guard `open` ada di sini.
   */
  function onWindowKeydown(event: KeyboardEvent): void {
    if (!open) return;
    onKeydown(event);
  }
</script>

<svelte:window onkeydown={onWindowKeydown} />

{#if open}
  <div class="kran-drawer-scrim" aria-hidden="true"></div>

  <div
    class="kran-drawer kran-drawer--full"
    role="dialog"
    aria-modal="true"
    aria-labelledby={headingId}
    tabindex="-1"
    bind:this={panel}
  >
    <div class="kran-drawer__head">
      <h2 class="kran-drawer__title" id={headingId} tabindex="-1" bind:this={headingElement}>
        {title}
      </h2>
      <Button variant="quiet" size="sm" type="button" onclick={requestClose}>
        {closeLabel}
      </Button>
    </div>

    <div class="kran-drawer__body">
      {#if confirming}
        <div class="kran-drawer__confirm" tabindex="-1" bind:this={confirmElement}>
          <p class="kran-drawer__confirm-title">{confirmTitle}</p>
          <div class="kran-actions">
            <Button type="button" onclick={keepEditing}>{keepEditingLabel}</Button>
            <Button variant="destructive" type="button" onclick={discardAndClose}>
              {discardLabel}
            </Button>
          </div>
        </div>
      {:else if loading}
        <LoadingState label={loadingLabel} />
      {:else if error !== ""}
        <ErrorState title={error} retryLabel={retryLabel} onretry={onretry} />
      {:else}
        {@render children?.()}
      {/if}
    </div>
  </div>
{/if}
