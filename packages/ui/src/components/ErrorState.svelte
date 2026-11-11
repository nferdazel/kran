<script lang="ts">
  /**
   * Keadaan gagal memuat data layar (T-292): apa yang gagal, lalu satu aksi coba lagi.
   *
   * Komponen ini tidak mengumumkan dirinya sendiri (bukan live region); halaman yang tahu kapan
   * kegagalan terjadi dan mengumumkannya satu kali. Label retry wajib dari pemakai (`app_retry`,
   * "Coba lagi"); aksi reload punya kalimat sendiri dan tidak pernah dipakai di sini.
   */
  import Button from "./Button.svelte";

  interface Props {
    title: string;
    body?: string;
    retryLabel: string;
    onretry?: () => void;
  }

  let { title, body = "", retryLabel, onretry }: Props = $props();
</script>

<div class="kran-error-state">
  <p class="kran-error-state__title">{title}</p>

  {#if body !== ""}
    <p class="kran-muted">{body}</p>
  {/if}

  <div class="kran-error-state__action">
    <Button type="button" onclick={onretry}>{retryLabel}</Button>
  </div>
</div>
