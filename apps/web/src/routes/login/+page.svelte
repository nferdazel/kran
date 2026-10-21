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

    const { error, response } = await api.POST("/api/v1/auth/login", {
      body: { username, password },
    });

    if (response.ok) {
      // Cookie sesi sudah terpasang oleh respons ini; lanjut ke shell aplikasi.
      await goto("/app/ledger");
      return;
    }

    submitting = false;
    errorMessage = loginErrorMessage(error);
  }
</script>

<svelte:head>
  <title>{m.common_app_title()} — {m.login_title()}</title>
</svelte:head>

<div class="login">
  <aside class="login-identity">
    <p class="login-brand">{m.common_brand_short()}</p>
    <p class="login-line">{m.login_intro()}</p>
  </aside>

  <section class="login-panel">
    <h1 class="login-title">{m.login_title()}</h1>


  <form class="kran-form" onsubmit={submit} novalidate>
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

    <p>
      <button class="kran-button kran-button--primary" type="submit" disabled={submitting}>
        {submitting ? m.login_submitting() : m.login_submit()}
      </button>
    </p>
  </form>
  </section>
</div>

<style>
  .login {
    display: grid;
    grid-template-columns: minmax(0, 1fr) minmax(18rem, 22rem);
    gap: var(--space-7);
    align-items: start;
    max-inline-size: 64rem;
    margin-inline: auto;
    padding-block: var(--space-6);
  }

  .login-identity {
    padding-block-start: var(--space-2);
    padding-inline-end: var(--space-5);
    border-inline-end: 1px solid var(--color-hairline);
    min-block-size: 18rem;
  }

  .login-brand {
    font-size: var(--text-xl);
    line-height: var(--line-height-tight);
    font-weight: 600;
    letter-spacing: -0.01em;
  }

  .login-line {
    margin-block-start: var(--space-2);
    max-inline-size: 34ch;
    color: var(--color-text-muted);
    font-size: var(--text-sm);
  }

  .login-panel {
    display: grid;
    gap: var(--space-4);
  }

  .login-title {
    font-size: var(--text-xl);
    line-height: var(--line-height-tight);
    font-weight: 600;
  }

  @media (max-width: 900px) {
    .login {
      grid-template-columns: minmax(0, 1fr);
      gap: var(--space-4);
      padding-block: var(--space-4);
    }

    .login-identity {
      border-inline-end: 0;
      padding-inline-end: 0;
      min-block-size: 0;
    }
  }
</style>
