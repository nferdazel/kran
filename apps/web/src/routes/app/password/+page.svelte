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
   */
  import { goto } from "$app/navigation";

  import * as m from "#lib/paraglide/messages.js";
  import { api } from "#lib/app/api.js";
  import { passwordProblemMessage } from "#lib/app/errors.js";
  import type { PageProps } from "./$types";

  let { data }: PageProps = $props();

  const session = $derived(data.session);

  let oldPassword = $state("");
  let newPassword = $state("");
  let errorMessage = $state("");
  let berhasil = $state(false);
  let submitting = $state(false);

  async function submit(event: SubmitEvent) {
    event.preventDefault();
    if (submitting) return;
    submitting = true;
    errorMessage = "";

    const { error, response } = await api.POST("/api/v1/auth/password", {
      body: { oldPassword, newPassword },
    });

    submitting = false;
    if (response.ok) {
      // Kata sandi lama sudah tidak berlaku; form tidak perlu menahan nilainya.
      oldPassword = "";
      newPassword = "";
      berhasil = true;
      return;
    }
    errorMessage = api.isProblem(error) ? passwordProblemMessage(error) : m.error_generic();
  }

  async function logout(): Promise<void> {
    await api.POST("/api/v1/auth/logout");
    await goto("/login");
  }
</script>

<svelte:head>
  <title>{m.common_app_title()} — {m.password_title()}</title>
</svelte:head>

<div class="kran-toolbar password-toolbar">
  <div>
    <h1 class="password-title">{m.password_title()}</h1>
  </div>
  <div class="password-session-actions">
    <span class="kran-badge kran-badge--primary">{m.app_signed_in_as({ name: session.fullName })}</span>
    <button class="kran-button" type="button" onclick={logout}>{m.app_logout()}</button>
  </div>
</div>

<section class="kran-card password-card" aria-labelledby="ganti-kata-sandi">
  <h2 id="ganti-kata-sandi">{m.password_title()}</h2>
  <p class="kran-muted">{m.password_intro()}</p>

  {#if session.mustChangePassword && !berhasil}
    <p class="kran-alert" role="status">{m.password_required_notice()}</p>
  {/if}

  {#if berhasil}
    <p class="kran-alert" role="status">{m.password_success()}</p>
    <p>
      <a class="kran-button kran-button--primary" href="/app">{m.password_continue()}</a>
    </p>
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
        <p class="kran-muted" id="kata-sandi-baru-hint">{m.password_hint()}</p>
      </div>

      {#if errorMessage}
        <p class="kran-alert" role="alert">{errorMessage}</p>
      {/if}

      <p>
        <button class="kran-button kran-button--primary" type="submit" disabled={submitting}>
          {submitting ? m.password_submitting() : m.password_submit()}
        </button>
      </p>
    </form>
  {/if}
</section>

<style>
  .password-toolbar {
    padding-block: var(--space-4);
    padding-inline: var(--space-4);
    border: 1px solid var(--color-hairline);
    border-radius: var(--radius-md);
    background: var(--color-surface-raised);
    margin-block-end: var(--space-4);
  }

  .password-title {
    margin: 0;
    font-size: var(--text-xl);
    line-height: var(--line-height-tight);
    font-weight: 600;
  }

  .password-session-actions {
    display: flex;
    flex-wrap: wrap;
    align-items: center;
    gap: var(--space-2);
  }

  .password-card {
    max-inline-size: 36rem;
  }
</style>
