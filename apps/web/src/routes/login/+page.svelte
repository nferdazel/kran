<script lang="ts">
  /**
   * Halaman masuk (spec §13, §18.2). Form native dengan label nyata + `autocomplete` supaya
   * pengelola kata sandi browser bekerja; setelah 200 token sesi sudah di cookie `HttpOnly`
   * (tidak ada di JS), jadi cukup lanjut ke `/app` lewat navigasi klien.
   *
   * Pesan gagal tidak mengungkapkan akun ada/tidak: 401 memakai pesan kredensial generik dari
   * katalog, dan 403 (terkunci/tidak aktif) hanya mungkin datang **setelah** kata sandi benar
   * (O-034), jadi pesannya boleh lebih spesifik untuk pemilik akun.
   *
   * Tata letak mengikuti DESIGN §11: satu bidang kerja sempit (`.kran-page`), tajuk layar bersama,
   * dan form bersama. Tidak ada CSS lokal di berkas ini; aturan visual tinggal di `packages/ui`.
   */
  import Alert from "@kran/ui/components/Alert.svelte";
  import Button from "@kran/ui/components/Button.svelte";

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

<div class="kran-page">
  <div class="kran-page-header">
    <div class="kran-stack">
      <p class="kran-muted">{m.common_brand_short()}</p>
      <h1 class="kran-page-header__title">{m.login_title()}</h1>
      <p class="kran-page-header__intro">{m.login_intro()}</p>
      <p class="kran-muted">{m.login_subtitle()}</p>
    </div>
  </div>

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
      <Alert tone="negative" title={errorMessage} />
    {/if}

    <div class="kran-actions">
      <Button variant="primary" type="submit" disabled={submitting}>
        {submitting ? m.login_submitting() : m.login_submit()}
      </Button>
    </div>
  </form>
</div>
