<script lang="ts">
  /**
   * Angka uang (DESIGN §2, §6, D-136).
   *
   * Nilai selalu lewat `formatMoney` dari `money.ts` — tidak ada format tangan, tidak ada float,
   * 2 desimal di semua tempat. Simbol mata uang menurut DESIGN §6 ada di judul kolom, bukan di tiap
   * sel; bila pemakai mengirim `currency` (mis. "IDR"), ia hanya diumumkan ke pembaca layar lewat
   * teks tersembunyi, bukan diulang di setiap angka. Pemisahnya `&#160;` supaya angka dan kode
   * mata uang tidak terbaca sebagai satu token.
   */
  import { formatMoney } from "../money.js";

  interface Props {
    /** Desimal polos 2 desimal, seperti kontrak API (mis. "1500000.00"). */
    value: string;
    currency?: string;
    muted?: boolean;
  }

  let { value, currency = "", muted = false }: Props = $props();

  const formatted = $derived(formatMoney(value));
  const className = $derived(muted ? "kran-money kran-muted" : "kran-money");
</script>

<span class={className}
  >{formatted}{#if currency !== ""}<span class="kran-visually-hidden">&#160;{currency}</span>{/if}</span
>
