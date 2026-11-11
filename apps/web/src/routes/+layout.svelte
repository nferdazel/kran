<script lang="ts">
  /**
   * Shell aplikasi (spec §14.2 `lib/app`, §14.3 indikator business date & mode, §17.1 landmark/
   * skip link/judul halaman, §15 tema, §16 bahasa).
   *
   * Catatan: isi `children` dibungkus `{#key locale}` supaya ganti bahasa membangun ulang subtree
   * (fungsi pesan Paraglide bukan store Svelte — lihat penjelasan di `lib/app/i18n.ts`).
   *
   * Dua hal sengaja berada di tempat tertentu (DESIGN §10–§11):
   *  - pengaturan tampilan (tema, bahasa) ada di **footer**, bukan di header: kontrol itu bukan
   *    bagian alur kerja dan tidak boleh menjadi tab-stop sebelum konten;
   *  - navigasi dikelompokkan menurut pekerjaan, bukan daftar datar sembilan tautan.
   */
  import "@kran/ui/tokens.css";
  import "@kran/ui/components.css";

  import { onMount } from "svelte";
  import { page } from "$app/state";

  import * as m from "#lib/paraglide/messages.js";
  import { APP_VERSION } from "#lib/version.js";
  import { formatDate } from "#lib/app/format.js";
  import {
    applyTheme,
    readChoice,
    setChoice,
    watchSystemTheme,
    type ResolvedTheme,
    type ThemeChoice,
  } from "#lib/app/theme.js";
  import {
    supportedLocales,
    switchLocale,
    syncDocumentLanguage,
    type AppLocale,
  } from "#lib/app/i18n.js";
  let { children } = $props();

  /**
   * `/app/*` chrome lives in `AppShell` (T-285). This layout only keeps the public frame (brand
   * header, skip link, `#main`) and the global footer, so the workspace never renders two
   * landmines worth of duplicate landmarks, skip links or `<main>` elements.
   */
  const isApp = $derived(page.url.pathname.startsWith("/app"));

  /**
   * Tanggal bisnis institusi (spec §14.3). `routes/app/+layout.ts` mengirim `undefined` bila
   * nilainya tidak diketahui (izin tidak ada atau permintaan gagal) dan `null` bila institusi
   * memang belum punya baris tanggal buku. Indikator hanya dirender pada dua kasus yang jujur itu:
   * tanggal nyata, atau "belum tersedia" yang memang keadaannya — tidak pernah tanggal karangan.
   * For `/app/*` the value is still exposed to pages through `page.data`.
   */
  const businessDate = $derived(page.data.businessDate as string | null | undefined);

  const themeChoices: readonly ThemeChoice[] = ["system", "light", "dark"];

  let choice = $state<ThemeChoice>("system");
  let resolved = $state<ResolvedTheme>("light");
  let locale = $state<AppLocale>("id");
  /** Diumumkan lewat live region (spec §17.1 status dinamis) — warna/tema bukan informasi visual saja. */
  let announcement = $state("");

  function themeLabel(value: ThemeChoice): string {
    if (value === "light") return m.common_theme_light();
    if (value === "dark") return m.common_theme_dark();
    return m.common_theme_system();
  }

  function localeLabel(value: AppLocale): string {
    return value === "en" ? m.common_locale_en() : m.common_locale_id();
  }

  onMount(() => {
    choice = readChoice();
    resolved = applyTheme(choice);
    locale = syncDocumentLanguage();
    return watchSystemTheme((next) => {
      resolved = next;
    });
  });

  function chooseTheme(value: ThemeChoice) {
    choice = value;
    resolved = setChoice(value);
    announcement = m.common_theme_changed({ theme: themeLabel(value) });
  }

  async function chooseLocale(value: AppLocale) {
    await switchLocale(value);
    locale = value;
    announcement = m.common_locale_changed({ language: localeLabel(value) });
  }
</script>

<!-- `/app/*` gets its skip link from `AppShell`; rendering this one too would give two. -->
{#if !isApp}
  <a class="kran-skip-link" href="#main">{m.common_skip_to_content()}</a>
{/if}

<div class="kran-shell {isApp ? 'kran-shell--host' : 'kran-shell--public'}" data-resolved-theme={resolved}>
  {#if isApp}
    <!-- `AppShell` in `routes/app/+layout.svelte` owns the skip link, sidebar, topbar and `#main`
         for the workspace; rendering the public frame here would duplicate those landmarks. -->
    {#key locale}
      {@render children()}
    {/key}
  {:else}
    <header class="kran-header">
      <div class="kran-header__brand">
        <p class="kran-header__title">
          <span>{m.common_app_title()}</span>
        </p>
      </div>

      {#if businessDate !== undefined}
        <div class="kran-header__meta">
          <!-- Indikator business date (spec §14.3): nilainya dari API, bukan placeholder. -->
          <p class="kran-business-date">
            <span class="kran-status-dot" aria-hidden="true"></span>
            <span class="kran-muted">{m.common_business_date_label()}:</span>
            <span class="kran-num"
              >{businessDate === null
                ? m.common_business_date_unknown()
                : formatDate(businessDate)}</span
            >
          </p>
        </div>
      {/if}
    </header>

    <main id="main" class="kran-main" tabindex="-1">
      {#key locale}
        {@render children()}
      {/key}
    </main>
  {/if}

  <footer class="kran-footer">
    <div class="kran-footer__inner">
      <p class="kran-muted">
        {m.common_app_title()}
        <!-- Versi dibaca dari VERSION lewat berkas generated (tools/gen-version.sh). Ini data,
             bukan teks yang perlu diterjemahkan; tanpa versi, laporan bug tidak bisa dipetakan
             ke kode yang benar-benar berjalan. -->
        <span class="kran-footer__version">v{APP_VERSION}</span>
      </p>

      <!-- Pengaturan tampilan: di luar alur Tab konten, terlihat dengan sendirinya (bukan modal,
           bukan popup) supaya tetap bisa dipakai keyboard-only tanpa membuka apa pun lebih dulu. -->
      <div class="kran-footer__settings" role="group" aria-label={m.common_display_label()}>
        <fieldset class="kran-fieldset kran-segmented">
          <legend>{m.common_theme_label()}</legend>
          {#each themeChoices as value (value)}
            <label class="kran-radio">
              <input
                type="radio"
                name="theme"
                value={value}
                checked={choice === value}
                onchange={() => chooseTheme(value)}
              />
              <span>{themeLabel(value)}</span>
            </label>
          {/each}
        </fieldset>

        <!-- Bahasa lewat grup radio (bukan `<select>`): sama-sama native, tetapi urutan fokus dan
             pergantian pilihan lewat panah dapat diuji keyboard-only tanpa bergantung pada popup
             bawaan browser (spec §17.2). -->
        <fieldset class="kran-fieldset kran-segmented">
          <legend>{m.common_locale_label()}</legend>
          {#each supportedLocales as value (value)}
            <label class="kran-radio">
              <input
                type="radio"
                name="locale"
                value={value}
                checked={locale === value}
                onchange={() => chooseLocale(value)}
              />
              <span>{localeLabel(value)}</span>
            </label>
          {/each}
        </fieldset>
      </div>
    </div>
  </footer>
</div>

<p class="kran-visually-hidden" role="status" aria-live="polite">{announcement}</p>
