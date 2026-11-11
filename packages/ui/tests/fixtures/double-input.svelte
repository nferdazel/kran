<script lang="ts">
  /**
   * Fixture uji: dua kontrol berlabel sama dalam satu render. Dipakai untuk membuktikan bahwa id
   * dibuat per instance (`$props.id()`), bukan dari teks label.
   */
  import Input from "../../src/components/Input.svelte";
</script>

<div>
  <Input label="Nominal setor" />
  <Input label="Nominal setor" />
</div>
