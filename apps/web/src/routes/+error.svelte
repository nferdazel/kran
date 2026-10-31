<script lang="ts">
  /**
   * Halaman galat aplikasi (spec §17.1). Tanpa berkas ini SvelteKit menampilkan halaman galat
   * bawaan berbahasa Inggris di aplikasi berbahasa Indonesia. Isinya sengaja tidak pernah
   * menampilkan pesan internal (`page.error.message` bisa memuat detail rute); yang ditampilkan
   * hanya status, jalan pulih, dan kode untuk dilaporkan.
   */
  import { page } from "$app/state";

  import * as m from "#lib/paraglide/messages.js";
</script>

<svelte:head>
  <title>{m.common_app_title()} — {m.error_page_title()}</title>
</svelte:head>

<section class="kran-page">
  <h1>{m.error_page_title()}</h1>
  <p class="kran-muted">{m.error_page_body()}</p>

  <div class="kran-alert kran-alert--neutral" role="status">
    <p class="kran-alert__title">{m.error_page_label({ status: page.status })}</p>
    {#if page.url.pathname}
      <p class="kran-print-ref">{page.url.pathname}</p>
    {/if}
  </div>

  <p>
    <!-- "Muat ulang" hanya untuk galat server: pada 404 alamatnya memang tidak ada, jadi memuat
         ulang URL yang sama hanya memutar. -->
    {#if page.status >= 500}
      <a class="kran-button kran-button--primary" href={page.url.pathname}>
        {m.error_page_reload()}
      </a>
    {/if}
    <a class="kran-button" href="/app">{m.error_page_back()}</a>
  </p>
</section>
