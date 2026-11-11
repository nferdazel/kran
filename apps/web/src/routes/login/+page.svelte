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
   * 403 `mfa_required` (O-071) juga hanya datang setelah kata sandi benar: server sudah menyetel
   * cookie sesi **setengah**, dan langkah kedua halaman ini mengirim kode ke
   * `POST /api/v1/auth/mfa/challenge` memakai cookie itu. Login ulang tidak diperlukan (dan tidak
   * akan membantu) sampai kodenya diterima.
   *
   * Tata letak mengikuti arah T-241: judul dan satu kalimat pengantar di kanvas, lalu satu bidang
   * datar bergaris rambut yang isinya hanya field, galat dan aksi. Tidak ada CSS lokal di berkas
   * ini; aturan visual tinggal di `packages/ui`.
   */
  import Alert from "@kran/ui/components/Alert.svelte";
  import Button from "@kran/ui/components/Button.svelte";
  import Input from "@kran/ui/components/Input.svelte";

  import { tick } from "svelte";

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
  let mfaRequired = $state(false);
  let code = $state("");

  // Kontrol `Input` membuat `id` sendiri, jadi fokus diarahkan lewat elemen aslinya.
  let usernameInput = $state<HTMLInputElement | null>(null);
  let passwordInput = $state<HTMLInputElement | null>(null);
  let codeInput = $state<HTMLInputElement | null>(null);

  /** Pindahkan fokus ke field yang bisa diperbaiki; `select` supaya mengetik langsung menimpa. */
  function focusField(element: HTMLInputElement | null, select = false) {
    if (!element) return;
    element.focus();
    if (select) element.select();
  }

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
      // 401 di layar masuk memakai pesan katalog yang sama dengan arah T-241, bukan pesan amplop
      // `error_unauthorized`: keduanya generik, dan yang ini yang sudah disetujui di layar.
      if (error.status === 401) return m.login_error();
      // 5xx bukan kredensial salah: server atau proxy yang tidak menjawab, dan operator perlu tahu
      // bahwa mengulang kata sandi tidak akan menolong (T-241 keadaan 8).
      if (error.status >= 500) return m.login_error_unreachable();
      return problemMessage(error);
    }
    return m.login_error_unreachable();
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
        // Kata sandi benar tetapi faktor kedua belum: cookie sesi setengah sudah terpasang,
        // jadi berpindah ke langkah kode alih-alih menampilkan kegagalan masuk.
        if (
          api.isProblem(error) &&
          error.status === 403 &&
          error.params?.reason === "mfa_required"
        ) {
          mfaRequired = true;
          code = "";
          // Field kode baru ada setelah render berikutnya.
          await tick();
          focusField(codeInput);
          return;
        }
        errorMessage = loginErrorMessage(error);
        // 401/400 = kata sandi atau isian yang bisa diperbaiki sekarang. 403 hanya muncul setelah
        // kata sandi benar dan 5xx bukan salah field, jadi fokus tidak dipindah di sana.
        if (api.isProblem(error) && (error.status === 401 || error.status === 400)) {
          focusField(passwordInput);
        }
        return;
      }

      await continueToApp();
    } catch {
      // Jaringan putus / proxy mati bukan "kredensial salah": tanpa penanganan ini `submitting`
      // tertahan `true`, tombol mati permanen dan pengguna tidak diberi tahu apa pun
      // (T-132/UI-2). `finally` mengembalikan tombol ke keadaan bisa ditekan.
      errorMessage = m.login_error_unreachable();
    } finally {
      submitting = false;
    }
  }

  async function submitCode(event: SubmitEvent) {
    event.preventDefault();
    if (submitting || code.trim().length === 0) return;
    submitting = true;
    errorMessage = "";

    try {
      const { error, response } = await api.POST("/api/v1/auth/mfa/challenge", {
        body: { code: code.trim() },
      });

      if (!response.ok) {
        if (api.isProblem(error) && error.params?.reason === "mfa_code_invalid") {
          errorMessage = m.login_mfa_invalid();
          // Nilai lama tetap terpilih supaya kode berikutnya langsung menimpanya.
          focusField(codeInput, true);
        } else {
          errorMessage = api.isProblem(error) ? problemMessage(error) : m.login_error_unreachable();
        }
        return;
      }

      await continueToApp();
    } catch {
      errorMessage = m.login_error_unreachable();
    } finally {
      submitting = false;
    }
  }

  /** Setelah sesi penuh (langsung atau sesudah kode): pilih tujuan sesuai izin lalu masuk. */
  async function continueToApp() {
    // Cookie sesi sudah terpasang. Landing harus mengikuti izin: `teller` tidak punya
    // `ledger.journal.read`, jadi mengarahkannya ke `/app/ledger` hanya menampilkan halaman
    // "tidak berizin". Ambil sesi sekali, lalu pilih tautan nav pertama yang boleh dibuka;
    // admin tetap mendarat di buku besar (tautan pertama).
    const { data: session } = await api.GET("/api/v1/auth/session");
    // Tujuan pendaratan dipilih fungsi yang sama dengan `/app` dan palette, supaya tiga jalur
    // masuk tidak pernah menyimpang.
    const target = landingHref(visibleNavLinks(appNavLinks, sessionPermissions(session)));
    await goto(target);
  }
</script>

<svelte:head>
  <title>{m.common_app_title()} — {m.login_title()}</title>
</svelte:head>

<div class="kran-signin">
  <div class="kran-signin__head">
    <h1 class="kran-page-header__title">{m.login_title()}</h1>
    <p class="kran-page-header__intro">{m.login_intro()}</p>
  </div>

  <!-- Tanpa `required`: `Input` menambahkan penanda `*` ke teks label, sementara arah T-241
       menggambar label polos, dan `novalidate` membuat validasi native tidak pernah berjalan.
       Tanpa `autofocus`: Tab pertama tetap harus sampai ke skip link (keyboard.spec). -->
  <form class="kran-signin__plane" onsubmit={mfaRequired ? submitCode : submit} novalidate>
    {#if errorMessage}
      <Alert tone="negative" title={errorMessage} />
    {/if}

    {#if mfaRequired}
      <Input
        label={m.login_mfa_code_label()}
        hint={m.login_mfa_prompt()}
        name="code"
        type="text"
        inputmode="numeric"
        autocomplete="one-time-code"
        autocapitalize="none"
        spellcheck="false"
        bind:value={code}
        bind:element={codeInput}
      />
    {:else}
      <Input
        label={m.login_username_label()}
        name="username"
        type="text"
        autocomplete="username"
        autocapitalize="none"
        spellcheck="false"
        bind:value={username}
        bind:element={usernameInput}
      />

      <Input
        label={m.login_password_label()}
        name="password"
        type="password"
        autocomplete="current-password"
        bind:value={password}
        bind:element={passwordInput}
      />
    {/if}

    <div class="kran-signin__actions">
      <Button variant="primary" type="submit" disabled={submitting}>
        {submitting
          ? m.login_submitting()
          : mfaRequired
            ? m.login_mfa_submit()
            : m.login_submit()}
      </Button>
    </div>
  </form>
</div>
