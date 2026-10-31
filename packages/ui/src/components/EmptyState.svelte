<script lang="ts">
  /**
   * Keadaan kosong (DESIGN §9: "Empty state jujur, tanpa data dummy").
   *
   * Judul dan penjelasan wajib datang dari pemakai. Komponen ini tidak menebak alasan kosong, tidak
   * mengisi angka contoh, dan tidak menawarkan aksi yang belum ada — aksi hanya dirender bila
   * pemakai mengirim snippet-nya.
   */
  import type { Snippet } from "svelte";

  interface Props {
    title: string;
    description?: string;
    action?: Snippet;
  }

  let { title, description = "", action }: Props = $props();
</script>

<div class="kran-empty-state">
  <p class="kran-empty-state__title">{title}</p>

  {#if description !== ""}
    <p class="kran-muted">{description}</p>
  {/if}

  {#if action}
    <div class="kran-empty-state__action">{@render action()}</div>
  {/if}
</div>
