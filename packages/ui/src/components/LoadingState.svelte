<script lang="ts">
  /**
   * Keadaan memuat (T-292): satu-satunya dari tiga keadaan yang diumumkan.
   *
   * `role="status"` membuat pembaca layar membacakan label saat muncul, dan `aria-busy` menandai
   * region yang sedang digantikan isinya. Kalimatnya datang dari pemakai (`<screen>_loading`),
   * berakhiran elipsis, dan menyebut objeknya.
   */
  interface Props {
    label: string;
  }

  let { label }: Props = $props();
</script>

<div class="kran-loading-state" role="status" aria-busy="true">
  <p>{label}</p>
</div>
