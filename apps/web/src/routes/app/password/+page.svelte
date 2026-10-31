<script lang="ts">
  /**
   * Ganti kata sandi sendiri (T-027, O-031). Ini satu-satunya rute berisi form kerja yang tetap
   * bisa dipakai selama `mustChangePassword` masih `true`; rute ber-izin lain ditolak server
   * (403 `password_change_required`) dan guard `/app` mengarahkan pengguna ke sini.
   *
   * Setelah berhasil: sesi **ini** tetap hidup (server hanya mencabut sesi lain milik pengguna yang
   * sama), jadi pengguna tidak perlu masuk ulang — cukup lanjut bekerja. Pesan langsungnya
   * ditampilkan di sini, bukan lewat pengalihan otomatis, supaya pengguna melihat sendiri bahwa
   * perubahan berhasil dan sesi lain sudah diputus.
   *
   * Tata letak mengikuti DESIGN §11: satu bidang kerja sempit (`.kran-page`), tajuk layar bersama,
   * dan form bersama. Tidak ada CSS lokal di berkas ini; aturan visual tinggal di `packages/ui`.
   */
  import { onMount } from "svelte";

  import Alert from "@kran/ui/components/Alert.svelte";
  import Button from "@kran/ui/components/Button.svelte";

  import * as m from "#lib/paraglide/messages.js";
  import { api } from "#lib/app/api.js";
  import { passwordProblemMessage } from "#lib/app/errors.js";
  import {
    loadPasswordPolicy,
    policyHint,
    type PasswordPolicy,
  } from "#lib/app/password.js";
  import {
    appNavLinks,
    landingHref,
    sessionPermissions,
    visibleNavLinks,
  } from "#lib/app/nav.js";
  import type { PageProps } from "./$types";

  let { data }: PageProps = $props();

  const session = $derived(data.session);

  /**
   * Tujuan setelah berhasil (T-133/UI-13): fungsi yang sama dengan login, `/app`, dan beranda, jadi
   * tiga jalur masuk itu tidak pernah menyimpang. Akun tanpa tautan mendarat di layar parameter
   * yang menjelaskan keadaannya, bukan di layar buntu.
   */
  const continueHref = $derived(
    landingHref(visibleNavLinks(appNavLinks, sessionPermissions(session))),
  );

  /** `null` = belum termuat atau gagal; petunjuk statis dipakai sebagai gantinya. */
  let policy = $state<PasswordPolicy | null>(null);
  const passwordHint = $derived(policy === null ? m.password_hint() : policyHint(policy));

  let oldPassword = $state("");
  let newPassword = $state("");
  let errorMessage = $state("");
  let berhasil = $state(false);
  let submitting = $state(false);

  onMount(() => {
    void (async () => {
      try {
        const { data, response } = await loadPasswordPolicy();
        if (response.ok && data) policy = data;
      } catch {
        // Kebijakan hanya petunjuk: gagal memuat tidak boleh menghalangi pengguna mengganti sandi.
      }
    })();
  });

  async function submit(event: SubmitEvent) {
    event.preventDefault();
    if (submitting) return;
    submitting = true;
    errorMessage = "";

    try {
      const { error, response } = await api.POST("/api/v1/auth/password", {
        body: { oldPassword, newPassword },
      });

      if (!response.ok) {
        errorMessage = api.isProblem(error) ? passwordProblemMessage(error) : m.error_generic();
        return;
      }
      // Kata sandi lama sudah tidak berlaku; form tidak perlu menahan nilainya.
      oldPassword = "";
      newPassword = "";
      berhasil = true;
    } catch {
      // Sama alasannya dengan layar masuk (T-132/UI-2): kegagalan jaringan tidak boleh
      // meninggalkan tombol `disabled` tanpa penjelasan.
      errorMessage = m.error_generic();
    } finally {
      submitting = false;
    }
  }

</script>

<svelte:head>
  <title>{m.common_app_title()} — {m.password_title()}</title>
</svelte:head>

<div class="kran-page">
  <!-- Identitas + tombol keluar ada di shell `/app` (T-132/UI-3): satu tempat untuk semua layar
       kerja, jadi layar ini tidak lagi menyediakan salinan kedua. -->
  <div class="kran-page-header">
    <div>
      <h1 class="kran-page-header__title">{m.password_title()}</h1>
      <p class="kran-page-header__intro">{m.password_intro()}</p>
    </div>
  </div>

  {#if session.mustChangePassword && !berhasil}
    <Alert tone="info" title={m.password_required_notice()} />
  {/if}

  {#if berhasil}
    <Alert tone="positive" title={m.password_success()} />
    <div class="kran-actions">
      <a class="kran-button kran-button--primary" href={continueHref}>{m.password_continue()}</a>
    </div>
  {:else}
    <form class="kran-form" onsubmit={submit} novalidate>
      <div class="kran-field">
        <label class="kran-label" for="kata-sandi-lama">{m.password_old_label()}</label>
        <input
          class="kran-input"
          id="kata-sandi-lama"
          name="oldPassword"
          type="password"
          autocomplete="current-password"
          bind:value={oldPassword}
          required
        />
      </div>

      <div class="kran-field">
        <label class="kran-label" for="kata-sandi-baru">{m.password_new_label()}</label>
        <input
          class="kran-input"
          id="kata-sandi-baru"
          name="newPassword"
          type="password"
          autocomplete="new-password"
          aria-describedby="kata-sandi-baru-hint"
          bind:value={newPassword}
          required
        />
        <p class="kran-muted" id="kata-sandi-baru-hint">{passwordHint}</p>
      </div>

      {#if errorMessage}
        <Alert tone="negative" title={errorMessage} />
      {/if}

      <div class="kran-actions">
        <Button variant="primary" type="submit" disabled={submitting}>
          {submitting ? m.password_submitting() : m.password_submit()}
        </Button>
      </div>
    </form>
  {/if}
</div>
