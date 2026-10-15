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
      await goto("/app");
      return;
    }

    submitting = false;
    errorMessage = loginErrorMessage(error);
  }
</script>

<svelte:head>
  <title>{m.common_app_title()} — {m.login_title()}</title>
</svelte:head>

<h1>{m.login_title()}</h1>

<section class="kran-card">
  <p class="kran-muted">{m.login_intro()}</p>

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
