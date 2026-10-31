<script lang="ts">
  /**
   * Badge status (DESIGN §1, §8: status = teks + bentuk + warna, tidak pernah warna saja).
   *
   * Bentuknya datang dari kotak/border `.kran-badge`, maknanya dari teks yang dikirim pemakai, dan
   * warnanya hanya penguat. Teks status **tidak** dibuat di sini: copy operator milik pemanggil
   * (i18n).
   */
  import type { Snippet } from "svelte";

  type StatusTone = "positive" | "negative" | "warning" | "info" | "neutral";

  interface Props {
    tone: StatusTone;
    children: Snippet;
  }

  let { tone, children }: Props = $props();

  const TONE_CLASS: Record<StatusTone, string> = {
    positive: "kran-badge kran-badge--ok",
    negative: "kran-badge kran-badge--danger",
    warning: "kran-badge kran-badge--warning",
    info: "kran-badge kran-badge--info",
    neutral: "kran-badge",
  };

  const badgeClass = $derived(TONE_CLASS[tone]);
</script>

<span class={badgeClass}>{@render children()}</span>
