<script module lang="ts">
  /**
   * Tiga jenis keadaan kosong (DESIGN §9, T-292). Kalimatnya berbeda karena sebabnya berbeda:
   * `no-data` = belum ada apa-apa (ajarkan langkah pertama), `no-match` = filter aktif tanpa hasil
   * (tawarkan hapus filter), `denied` = fakta izin (sebut izin dan siapa yang memberikannya).
   *
   * Tanpa `kind` = keadaan yang bukan salah satu dari ketiganya (mis. resource tidak ditemukan);
   * kalimatnya tetap dari pemakai, dan tidak ada aksi yang dirender.
   */
  export type EmptyKind = "no-data" | "no-match" | "denied";
</script>

<script lang="ts">
  /**
   * Keadaan kosong (DESIGN §9: "Empty state jujur, tanpa data dummy").
   *
   * Judul dan penjelasan wajib datang dari pemakai. Komponen ini tidak menebak alasan kosong, tidak
   * mengisi angka contoh, dan tidak menawarkan aksi yang belum ada — aksi hanya dirender untuk
   * `kind="no-match"`, karena hanya keadaan itu yang punya aksi standar (`common_filter_clear`).
   */
  import type { Snippet } from "svelte";

  interface Props {
    title: string;
    description?: string;
    /** Sebab kosong; menentukan apakah aksi dirender. Tanpa `kind` = keadaan lain. */
    kind?: EmptyKind;
    action?: Snippet;
  }

  let { title, description = "", kind, action }: Props = $props();
</script>

<div class="kran-empty-state" data-kind={kind}>
  <p class="kran-empty-state__title">{title}</p>

  {#if description !== ""}
    <p class="kran-muted">{description}</p>
  {/if}

  {#if kind === "no-match" && action}
    <div class="kran-empty-state__action">{@render action()}</div>
  {/if}
</div>
