<script lang="ts">
  /**
   * Beranda shell (spec §14.3, §15.4 status bukan hanya warna, §16.2 format angka/uang,
   * §17.1 hierarki heading).
   *
   * Isi nyata tiap modul menyusul (T-012 dan fase berikutnya); halaman ini membuktikan design
   * token, tema, bahasa, ICU plural, format `Intl`, dan pola status/landmark bekerja.
   */
  import * as m from "#lib/paraglide/messages.js";
  import { formatAccountCount, formatIdr } from "#lib/app/format.js";

  // Dihitung di body komponen (bukan module scope) supaya ikut dibangun ulang saat bahasa
  // berganti — layout membungkus children dengan `{#key locale}`.
  const statuses = [
    { kind: "ok", icon: "✔", label: m.common_status_ok() },
    { kind: "warning", icon: "▲", label: m.common_status_warning() },
    { kind: "danger", icon: "✖", label: m.common_status_danger() },
  ] as const;

  const contohUang = "1234567.89"; // string desimal, seperti yang dikirim API (spec §13)
</script>

<svelte:head>
  <title>{m.common_app_title()} — {m.common_nav_home()}</title>
</svelte:head>

<h1>{m.common_home_title()}</h1>
<p>{m.common_home_intro()}</p>

<section class="cbs-card" aria-labelledby="status-heading">
  <h2 id="status-heading">{m.common_status_heading()}</h2>
  <p class="cbs-muted">{m.common_status_hint()}</p>
  <ul class="cbs-status-list">
    {#each statuses as status (status.kind)}
      <li class="cbs-status cbs-status--{status.kind}">
        <span class="cbs-status__icon" aria-hidden="true">{status.icon}</span>
        <span>{status.label}</span>
      </li>
    {/each}
  </ul>
</section>

<section class="cbs-card" aria-labelledby="demo-heading">
  <h2 id="demo-heading">{m.common_demo_heading()}</h2>
  <p>
    <span class="cbs-muted">{m.common_demo_accounts()}:</span>
    {formatAccountCount(3)}
  </p>
  <p>
    <span class="cbs-muted">{m.common_demo_amount()}:</span>
    {formatIdr(contohUang)}
  </p>
</section>
