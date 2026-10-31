<script lang="ts">
  /**
   * Kotak pesan dengan judul + jalan pulih (DESIGN §7: "Tidak ada 'Terjadi kesalahan sistem' tanpa
   * langkah berikutnya").
   *
   * `role="alert"` hanya untuk kegagalan (tone `negative`); sisanya `role="status"` supaya
   * pengumuman tidak memotong pembaca layar (DESIGN §8: assertive khusus kegagalan transaksi).
   * Judul sengaja `<p>`, bukan heading: kotak pesan bisa muncul di atas `<h1>` halaman dan urutan
   * heading yang melompat adalah temuan axe tersendiri.
   */
  import type { Snippet } from "svelte";

  type AlertTone = "positive" | "negative" | "warning" | "info" | "neutral";

  interface Props {
    tone: AlertTone;
    title: string;
    /** Nomor referensi transaksi (DESIGN §7), ditampilkan apa adanya. */
    reference?: string;
    /** Isi pesan + aksi pemulihan (mis. tombol "Ulangi"). */
    children?: Snippet;
  }

  let { tone, title, reference = "", children }: Props = $props();

  const urgent = $derived(tone === "negative");
  const alertClass = $derived(`kran-alert kran-alert--${tone}`);
</script>

<div class={alertClass} role={urgent ? "alert" : "status"}>
  <p class="kran-alert__title">{title}</p>

  {#if children}
    {@render children()}
  {/if}

  {#if reference !== ""}
    <p class="kran-print-ref">{reference}</p>
  {/if}
</div>
