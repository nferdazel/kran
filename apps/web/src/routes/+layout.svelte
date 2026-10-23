<script lang="ts">
  /**
   * Shell aplikasi (spec §14.2 `lib/app`, §14.3 indikator business date & mode, §17.1 landmark/
   * skip link/judul halaman, §15 tema, §16 bahasa).
   *
   * Catatan: isi `children` dibungkus `{#key locale}` supaya ganti bahasa membangun ulang subtree
   * (fungsi pesan Paraglide bukan store Svelte — lihat penjelasan di `lib/app/i18n.ts`).
   */
  import "@kran/ui/tokens.css";
  import "@kran/ui/components.css";

  import { onMount } from "svelte";
  import { page } from "$app/state";

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
  import { appNavLinks, isActiveHref } from "#lib/app/nav.js";

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

<a class="kran-skip-link" href="#main">{m.common_skip_to_content()}</a>

<div class="kran-shell" data-resolved-theme={resolved}>
  <header class="kran-header">
    <div class="kran-header__brand">
      <span class="kran-header__badge" aria-hidden="true">K</span>
      <p class="kran-header__title">
        <span>{m.common_app_title()}</span>
      </p>
    </div>

    <div class="kran-header__meta">
      <!-- Indikator business date selalu tampak (spec §14.3). Nilainya menyusul pada T-012. -->
      <p class="kran-business-date">
        <span class="kran-status-dot" aria-hidden="true"></span>
        <span class="kran-muted">{m.common_business_date_label()}:</span>
        <span class="kran-num">{m.common_business_date_unknown()}</span>
      </p>

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
  </header>

  <nav class="kran-nav" aria-label={m.common_nav_label()}>
    <div class="kran-nav__inner">
      <ul>
        {#each appNavLinks as link (link.href)}
          <li>
            <a
              class="kran-link"
              href={link.href}
              aria-current={isActiveHref(page.url.pathname, link.href) ? "page" : undefined}
            >
              {link.label()}
            </a>
          </li>
        {/each}
        <!-- Tautan masuk (O-033) hanya di halaman publik; di area kerja tempatnya di toolbar `/app`
             bersama aksi "Keluar" (yang punya konteks sesi). -->
        {#if !page.url.pathname.startsWith("/app")}
          <li><a class="kran-link" href="/login">{m.common_nav_login()}</a></li>
        {/if}
      </ul>

      {#if page.url.pathname.startsWith("/app")}
        <div class="kran-nav__shortcut" aria-hidden="true">
          <span class="kran-muted">{m.palette_heading()}</span>
          <span class="kran-kbd">Ctrl K</span>
        </div>
      {/if}
    </div>
  </nav>

  <main id="main" class="kran-main" tabindex="-1">
    {#key locale}
      {@render children()}
    {/key}
  </main>

  <footer class="kran-footer">
    <div class="kran-footer__inner">
      <p class="kran-muted">{m.common_app_title()}</p>
    </div>
  </footer>
</div>

<p class="kran-visually-hidden" role="status" aria-live="polite">{announcement}</p>
