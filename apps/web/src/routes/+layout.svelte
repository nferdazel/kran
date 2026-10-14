<script lang="ts">
  /**
   * Shell aplikasi (spec §14.2 `lib/app`, §14.3 indikator business date & mode, §17.1 landmark/
   * skip link/judul halaman, §15 tema, §16 bahasa).
   *
   * Catatan: isi `children` dibungkus `{#key locale}` supaya ganti bahasa membangun ulang subtree
   * (fungsi pesan Paraglide bukan store Svelte — lihat penjelasan di `lib/app/i18n.ts`).
   */
  import "@cbs/ui/tokens.css";
  import "@cbs/ui/components.css";

  import { onMount } from "svelte";

  import * as m from "#lib/paraglide/messages.js";
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

<a class="cbs-skip-link" href="#main">{m.common_skip_to_content()}</a>

<div class="cbs-shell" data-resolved-theme={resolved}>
  <header class="cbs-header">
    <p class="cbs-header__brand">
      <span>{m.common_app_title()}</span>
    </p>

    <div class="cbs-header__meta">
      <!-- Indikator business date selalu tampak (spec §14.3). Nilainya menyusul pada T-012. -->
      <p class="cbs-business-date">
        <span class="cbs-muted">{m.common_business_date_label()}:</span>
        <span>{m.common_business_date_unknown()}</span>
      </p>

      <fieldset class="cbs-fieldset">
        <legend>{m.common_theme_label()}</legend>
        {#each themeChoices as value (value)}
          <label class="cbs-radio">
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
      <fieldset class="cbs-fieldset">
        <legend>{m.common_locale_label()}</legend>
        {#each supportedLocales as value (value)}
          <label class="cbs-radio">
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
  </header>

  <nav class="cbs-nav" aria-label={m.common_nav_label()}>
    <ul>
      <li><a class="cbs-link" href="/">{m.common_nav_home()}</a></li>
    </ul>
  </nav>

  <main id="main" class="cbs-main" tabindex="-1">
    {#key locale}
      {@render children()}
    {/key}
  </main>

  <footer class="cbs-footer">
    <p class="cbs-muted">{m.common_app_title()}</p>
  </footer>
</div>

<p class="cbs-visually-hidden" role="status" aria-live="polite">{announcement}</p>
