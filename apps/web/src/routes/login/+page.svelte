<script lang="ts">
  /**
   * Halaman masuk (spec §13, §18.2). Form native dengan label nyata + `autocomplete` supaya
   * pengelola kata sandi browser bekerja; setelah 200 token sesi sudah di cookie `HttpOnly`
   * (tidak ada di JS), jadi cukup lanjut ke `/app` lewat navigasi klien.
   *
   * Pesan gagal tidak mengungkapkan akun ada/tidak: 401 memakai pesan kredensial generik dari
   * katalog, dan 403 (terkunci/tidak aktif) hanya mungkin datang **setelah** kata sandi benar
   * (O-034), jadi pesannya boleh lebih spesifik untuk pemilik akun.
   */
  import { goto } from "$app/navigation";

  import * as m from "#lib/paraglide/messages.js";
  import { api } from "#lib/app/api.js";
  import { problemMessage } from "#lib/app/errors.js";
  import {
    appNavLinks,
    landingHref,
    sessionPermissions,
    visibleNavLinks,
  } from "#lib/app/nav.js";

  let username = $state("");
  let password = $state("");
  let errorMessage = $state("");
  let submitting = $state(false);

  function loginErrorMessage(error: unknown): string {
    if (api.isProblem(error)) {
      // 403 hanya dikirim **setelah** kata sandi diverifikasi benar (O-034), jadi menyebut alasan
      // terkunci/tidak aktif di sini tidak memberi tahu apa pun kepada orang yang tidak memegang
      // kata sandinya — sementara pemilik akun justru perlu tahu kenapa ia ditolak.
      if (error.status === 403) {
        const reason = error.params?.reason;
        if (reason === "locked") return m.login_locked();
        if (reason === "inactive") return m.login_inactive();
        return m.login_error();
      }
      return problemMessage(error);
    }
    return m.error_generic();
  }

  async function submit(event: SubmitEvent) {
    event.preventDefault();
    if (submitting) return;
    submitting = true;
    errorMessage = "";

    try {
      const { error, response } = await api.POST("/api/v1/auth/login", {
        body: { username, password },
      });

      if (!response.ok) {
        errorMessage = loginErrorMessage(error);
        return;
      }

      // Cookie sesi sudah terpasang. Landing harus mengikuti izin: `teller` tidak punya
      // `ledger.journal.read`, jadi mengarahkannya ke `/app/ledger` hanya menampilkan halaman
      // "tidak berizin". Ambil sesi sekali, lalu pilih tautan nav pertama yang boleh dibuka;
      // admin tetap mendarat di buku besar (tautan pertama).
      const { data: session } = await api.GET("/api/v1/auth/session");
      // Tujuan pendaratan dipilih fungsi yang sama dengan `/app` dan palette, supaya tiga jalur
      // masuk tidak pernah menyimpang.
      const target = landingHref(visibleNavLinks(appNavLinks, sessionPermissions(session)));
      await goto(target);
    } catch {
      // Jaringan putus / proxy mati bukan "kredensial salah": tanpa penanganan ini `submitting`
      // tertahan `true`, tombol mati permanen dan pengguna tidak diberi tahu apa pun
      // (T-132/UI-2). `finally` mengembalikan tombol ke keadaan bisa ditekan.
      errorMessage = m.error_generic();
    } finally {
      submitting = false;
    }
  }
</script>

<svelte:head>
  <title>{m.common_app_title()} — {m.login_title()}</title>
</svelte:head>

<div class="login">
  <aside class="login-identity">
    <div class="login-badge-seal" aria-hidden="true">
      <span>KRAN</span>
    </div>
    <p class="login-brand">{m.common_brand_short()}</p>
    <p class="login-line">{m.login_intro()}</p>

  </aside>

  <section class="login-panel">
    <div class="login-card">
      <div class="login-card__head">
        <h1 class="login-title">{m.login_title()}</h1>
        <p class="kran-muted login-subtitle">{m.login_subtitle()}</p>
      </div>

      <form class="kran-form login-form" onsubmit={submit} novalidate>
        <div class="kran-field">
          <label class="kran-label" for="login-username">{m.login_username_label()}</label>
          <input
            class="kran-input"
            id="login-username"
            name="username"
            type="text"
            autocomplete="username"
            autocapitalize="none"
            spellcheck="false"
            bind:value={username}
            required
          />
        </div>

        <div class="kran-field">
          <label class="kran-label" for="login-password">{m.login_password_label()}</label>
          <input
            class="kran-input"
            id="login-password"
            name="password"
            type="password"
            autocomplete="current-password"
            bind:value={password}
            required
          />
        </div>

        {#if errorMessage}
          <p class="kran-alert" role="alert">{errorMessage}</p>
        {/if}

        <p class="login-submit-row">
          <button class="kran-button kran-button--primary login-button" type="submit" disabled={submitting}>
            {submitting ? m.login_submitting() : m.login_submit()}
          </button>
        </p>
      </form>
    </div>
  </section>
</div>

<style>
  .login {
    display: grid;
    grid-template-columns: minmax(0, 1.2fr) minmax(20rem, 26rem);
    gap: var(--space-7);
    align-items: center;
    max-inline-size: 68rem;
    margin-inline: auto;
    padding-block: var(--space-7);
    min-block-size: calc(100vh - 180px);
  }

  .login-identity {
    display: flex;
    flex-direction: column;
    gap: var(--space-3);
    padding-block: var(--space-4);
    padding-inline-end: var(--space-6);
  }

  .login-badge-seal {
    display: inline-flex;
    align-items: center;
    justify-content: center;
    inline-size: 3rem;
    block-size: 3rem;
    border-radius: var(--radius-sm);
    background: var(--color-primary);
    color: var(--color-text-on-primary);
    font-weight: 700;
    font-size: var(--text-sm);
    letter-spacing: 0.05em;
  }

  .login-brand {
    font-size: var(--text-xl);
    line-height: var(--line-height-tight);
    font-weight: 600;
    letter-spacing: -0.01em;
  }

  .login-line {
    max-inline-size: 38ch;
    color: var(--color-text-muted);
    font-size: var(--text-base);
    line-height: 1.5;
  }



  .login-panel {
    display: flex;
    justify-content: center;
  }

  .login-card {
    width: 100%;
    padding-block: var(--space-6);
    padding-inline: var(--space-6);
    border: 1px solid var(--color-hairline);
    border-radius: var(--radius-lg);
    background: var(--color-surface-raised);
    box-shadow: var(--shadow-1);
  }

  .login-card__head {
    margin-block-end: var(--space-5);
  }

  .login-title {
    font-size: var(--text-xl);
    line-height: var(--line-height-tight);
    font-weight: 600;
  }

  .login-subtitle {
    margin-block-start: var(--space-1);
    font-size: var(--text-xs);
  }

  .login-form {
    max-inline-size: none;
    width: 100%;
  }

  .login-submit-row {
    margin-block-start: var(--space-2);
    margin-block-end: 0;
  }

  .login-button {
    width: 100%;
    justify-content: center;
  }

  @media (max-width: 900px) {
    .login {
      grid-template-columns: minmax(0, 1fr);
      gap: var(--space-5);
      padding-block: var(--space-4);
      min-block-size: 0;
    }

    .login-identity {
      border-inline-end: 0;
      padding-inline-end: 0;
      border-block-end: 1px solid var(--color-hairline);
      padding-block-end: var(--space-4);
    }
  }
</style>
