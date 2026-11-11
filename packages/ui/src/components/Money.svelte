<script lang="ts">
  /**
   * Angka uang (DESIGN §2, §6, D-136).
   *
   * Nilai selalu lewat `formatMoney` dari `money.ts` — tidak ada format tangan, tidak ada float,
   * 2 desimal di semua tempat. Simbol mata uang menurut DESIGN §6 ada di judul kolom, bukan di tiap
   * sel: komponen ini tidak punya prop `currency`, jadi keluarannya identik untuk setiap pemanggil.
   *
   * `locale` wajib diteruskan pemakai (aplikasi ini dwibahasa id/en, DESIGN §6). Tidak ada prop
   * `muted`: DESIGN §3 melarang angka uang memakai teks-2/muted, terutama di tema gelap. Nilai
   * kosong dirender kosong, bukan melempar galat: sel tanpa angka adalah keadaan sah.
   */
  import { formatMoney } from "../money.js";

  interface Props {
    /** Desimal polos 2 desimal, seperti kontrak API (mis. "1500000.00"). */
    value: string;
    /** Locale angka, mis. "id-ID" atau "en-US". */
    locale?: string;
  }

  let { value, locale = "id-ID" }: Props = $props();

  const formatted = $derived(value.trim() === "" ? "" : formatMoney(value, { locale }));
</script>

<span class="kran-money">{formatted}</span>
