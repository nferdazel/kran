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
  import { goto } from "$app/navigation";
  import { resolve } from "$app/paths";
  import { page } from "$app/state";

  import * as m from "#lib/paraglide/messages.js";
  import { api } from "#lib/app/api.js";
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
  import {
    appNavLinks,
    groupVisibleLinks,
    isActiveHref,
    sessionPermissions,
    visibleNavLinks,
  } from "#lib/app/nav.js";

  let { children } = $props();

  /**
   * Menu disaring per izin (spec §13). `page.data` adalah gabungan data seluruh `load` rute ini,
   * jadi `session` dari `routes/app/+layout.ts` tersedia di sini; selama belum termuat, izin
   * dianggap kosong (tautan berizin disembunyikan, bukan ditampilkan lalu ditolak server).
   */
  const navLinks = $derived(visibleNavLinks(appNavLinks, sessionPermissions(page.data.session)));
  const navGroups = $derived(groupVisibleLinks(navLinks));

  /**
   * Tanggal bisnis institusi (spec §14.3). `routes/app/+layout.ts` mengirim `undefined` bila
   * nilainya tidak diketahui (izin tidak ada atau permintaan gagal) dan `null` bila institusi
   * memang belum punya baris tanggal buku. Indikator hanya dirender pada dua kasus yang jujur itu:
   * tanggal nyata, atau "belum tersedia" yang memang keadaannya — tidak pernah tanggal karangan.
   */
  const businessDate = $derived(page.data.businessDate as string | null | undefined);

  /**
   * Identitas pemegang sesi untuk shell (T-132/UI-3). Sebelumnya logout hanya ada di `/app` dan
   * `/app/password`; teller di terminal bersama tidak bisa mengakhiri sesi dari layar kerjanya.
   * Shell adalah tempatnya: satu tombol, tersedia di setiap rute `/app`.
   */
  const sessionName = $derived(
    (page.data.session as { fullName?: string } | undefined)?.fullName ?? "",
  );

  async function logout(): Promise<void> {
    try {
      await api.POST("/api/v1/auth/logout");
    } catch {
      // Sesi yang sudah tidak sah tetap harus membawa pengguna keluar dari layar ini: kegagalan
      // jaringan tidak boleh membuat tombol "Keluar" tampak tidak bekerja.
    }
    await goto(resolve("/login"));
  }

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

<div class="kran-shell {page.url.pathname.startsWith('/app') ? 'kran-shell--app' : 'kran-shell--public'}" data-resolved-theme={resolved}>
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

  <!-- App navigation belongs to the workspace only. Public pages (login) must not advertise
       destinations that require a session; theme/language live in the footer for every page. -->
  {#if page.url.pathname.startsWith("/app")}
    <nav class="kran-nav" aria-label={m.common_nav_label()}>
      <div class="kran-nav__inner">
        <div class="kran-sidebar-brand">
          <div>
            <strong class="kran-sidebar-title">{m.common_brand_short()}</strong>
            <span class="kran-sidebar-subtitle">{m.app_sidebar_subtitle()}</span>
          </div>
        </div>

        {#each navGroups as group (group.id)}
          <div class="kran-nav__group">
            <!-- Label kelompok, bukan heading: nav muncul sebelum `<h1>` halaman dan heading
                 tingkat 2 di depannya membuat urutan heading dimulai dari level 2. -->
            <p class="kran-nav__group-title" id="nav-group-{group.id}">{group.label()}</p>
            <ul aria-labelledby="nav-group-{group.id}">
              {#each group.links as link (link.href)}
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
            </ul>
          </div>
        {/each}

        <div class="kran-nav__shortcut" aria-hidden="true">
          <span class="kran-muted">{m.palette_heading()}</span>
          <span class="kran-kbd">Ctrl K</span>
        </div>

        {#if sessionName !== ""}
          <div class="kran-nav__session">
            <p class="kran-nav__who">{m.app_signed_in_as({ name: sessionName })}</p>
            <a class="kran-button" href={resolve("/app/password")}>{m.app_change_password()}</a>
            <button class="kran-button" type="button" onclick={logout}>{m.app_logout()}</button>
          </div>
        {/if}
      </div>
    </nav>
  {/if}

  <main id="main" class="kran-main" tabindex="-1">
    {#key locale}
      {@render children()}
    {/key}
  </main>

  <footer class="kran-footer">
    <div class="kran-footer__inner">
      <p class="kran-muted">{m.common_app_title()}</p>

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
