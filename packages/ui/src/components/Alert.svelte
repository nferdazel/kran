<script lang="ts">
  /**
   * Kotak pesan dengan judul + jalan pulih (DESIGN §7: "Tidak ada 'Terjadi kesalahan sistem' tanpa
   * langkah berikutnya").
   *
   * `role="alert"` hanya untuk kegagalan/peringatan; sisanya `role="status"` supaya pengumuman tidak
   * memotong pembaca layar (DESIGN §8). Judul, isi, dan aksi datang dari pemakai — komponen ini
   * tidak mengarang copy atau rujukan.
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

  const urgent = $derived(tone === "negative" || tone === "warning");
  const alertClass = $derived(`kran-alert kran-alert--${tone}`);
</script>

<div class={alertClass} role={urgent ? "alert" : "status"}>
  <h2 class="kran-alert__title">{title}</h2>

  {#if children}
    {@render children()}
  {/if}

  {#if reference !== ""}
    <p class="kran-print-ref">{reference}</p>
  {/if}
</div>
