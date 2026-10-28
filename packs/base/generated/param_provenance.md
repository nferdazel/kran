<!-- JANGAN EDIT — dihasilkan tools/paramgen dari modules/*/seeds/params.yaml -->
<!-- Tabel asal-usul nilai seed (D-095). Jangan diedit: ubah `provenance` di -->
<!-- `modules/*/seeds/params.yaml`, lalu jalankan `./task paramgen-gen`. -->

# Asal-usul nilai seed parameter

Kelas mengikuti D-095 (O-066). `disemai` = pack yang menerima nilai awal dari
`default_pack`; `-` berarti tidak disemai. Kelas `regulasi-tidak-disemai` dan
`belum-bermakna` dilarang punya `default_pack` (ditegakkan `paramgen`).

| key | kelas | disemai | penanda | catatan |
|---|---|---|---|---|
| `daycloser.auto.enabled` | kebijakan | base | - | Saklar penjadwal harian. Default mati: tidak ada penutupan yang berjalan tanpa keputusan operator. |
| `daycloser.auto.run_at` | kebijakan | base | - | Jam lokal penutupan otomatis (HH:MM). Bentuk selain HH:MM ditolak saat dibaca, bukan ditebak. |
| `daycloser.auto.utc_offset_minutes` | teknis | base | - | Selisih zona institusi dari UTC dalam menit (WIB = 420). Batas ±14 jam = batas zona waktu dunia. |
| `daycloser.chunk_size` | teknis | base | - | Jumlah entitas per chunk. Angka awal 1000; disetel setelah benchmark EOD (T-140). |
| `daycloser.max_attempts` | teknis | base | - | Percobaan maksimum per chunk/task sebelum dinyatakan FAILED. |
| `daycloser.postcheck.subledger_gl_accounts` | kebijakan | base | `NEEDS-COMPLIANCE-REVIEW` | Akun GL kewajiban untuk total subledger simpanan; pemetaan per jenis produk = open item. |
| `daycloser.precheck.suspense_accounts` | kebijakan | base | `NEEDS-COMPLIANCE-REVIEW` | Daftar akun selisih/suspense yang wajib nol sebelum tutup; nilai awal hanya 101.9 karena akun antar-kantor belum ada. |
| `daycloser.retry_backoff_seconds` | teknis | base | - | Jeda tetap antar percobaan. Backoff eksponensial menyusul bersama worker pool (T-140). |
| `daycloser.txn_policy_during_close` | kebijakan | base | `NEEDS-COMPLIANCE-REVIEW` | Pilihan kebijakan operasional institusi; nilai ALLOW belum diuji terhadap task penutup nyata (T-140). |
| `ledger.coa.code_pattern` | teknis | base | - | - |
| `ledger.posting.batch_size` | teknis | base | - | - |
| `ledger.posting.lease_seconds` | teknis | base | - | - |
| `ledger.posting.max_attempts` | teknis | base | - | - |
| `ledger.posting.poll_interval_ms` | teknis | base | - | - |
| `ledger.posting.retry_backoff_seconds` | teknis | base | - | - |
| `party.cif.format` | kebijakan | base | - | - |
| `party.identity.doc_lengths` | kebijakan | base | `NEEDS-COMPLIANCE-REVIEW` | - |
| `party.identity.doc_types` | kebijakan | base | `NEEDS-COMPLIANCE-REVIEW` | - |
| `party.identity.number_max_length` | kebijakan | base | - | - |
| `party.kyc.default_risk_level` | kebijakan | base | `NEEDS-COMPLIANCE-REVIEW` | - |
| `party.kyc.review_months` | kebijakan | base | `NEEDS-COMPLIANCE-REVIEW` | - |
| `party.kyc.risk_levels` | kebijakan | base | `NEEDS-COMPLIANCE-REVIEW` | - |
| `party.person.sex_values` | kebijakan | base | `NEEDS-COMPLIANCE-REVIEW` | - |
| `platform.calendar.fiscal_year_start_month` | kebijakan | base | - | - |
| `platform.calendar.weekend_days` | kebijakan | base | - | - |
| `platform.idempotency.ttl_hours` | teknis | base | - | - |
| `platform.realtime.max_topic_len` | teknis | base | - | - |
| `platform.realtime.max_topics` | teknis | base | - | - |
| `platform.security.lockout_minutes` | kebijakan | base | - | - |
| `platform.security.max_failed_logins` | kebijakan | base | - | - |
| `platform.security.mfa.digits` | teknis | base | - | - |
| `platform.security.mfa.drift_steps` | teknis | base | - | - |
| `platform.security.mfa.enabled` | teknis | base | `NEEDS-COMPLIANCE-REVIEW` | default mati = penerimaan risiko pemilik untuk pilot (spec §18.2), bukan klaim patuh |
| `platform.security.mfa.issuer` | teknis | base | - | - |
| `platform.security.mfa.period_seconds` | teknis | base | - | - |
| `platform.security.password_history_count` | kebijakan | base | - | - |
| `platform.security.password_min_classes` | kebijakan | base | - | - |
| `platform.security.password_min_length` | kebijakan | base | - | - |
| `platform.security.password_pbkdf2_iterations` | teknis | base | `HUMAN-REVIEW-REQUIRED` | kripto — biaya PBKDF2; wajib ditinjau ulang, bukan angka final |
| `platform.security.session_absolute_minutes` | kebijakan | base | - | - |
| `platform.security.session_idle_minutes` | kebijakan | base | - | - |
| `platform.ui.shortcut.deposit` | kebijakan | base | - | - |
| `platform.ui.shortcut.transfer` | kebijakan | base | - | - |
| `platform.ui.shortcut.withdrawal` | kebijakan | base | - | - |
| `product.savings.admin_fee` | komersial-konservatif | base | `NEEDS-COMPLIANCE-REVIEW` | tidak menagih; angka final menunggu pemilik |
| `product.savings.day_count_basis` | regulasi-tidak-disemai | - | `NEEDS-COMPLIANCE-REVIEW` | - |
| `product.savings.interest_posting` | regulasi-tidak-disemai | - | `NEEDS-COMPLIANCE-REVIEW` | - |
| `product.savings.interest_rate` | regulasi-tidak-disemai | - | `NEEDS-COMPLIANCE-REVIEW` | - |
| `product.savings.min_balance` | komersial-konservatif | base | `NEEDS-COMPLIANCE-REVIEW` | tidak menagih; angka final menunggu pemilik |
| `product.savings.rounding_mode` | regulasi-tidak-disemai | - | `NEEDS-COMPLIANCE-REVIEW` | - |
| `product.savings.rounding_scale` | regulasi-tidak-disemai | - | `NEEDS-COMPLIANCE-REVIEW` | - |
| `teller.cash.limit_deposit` | kebijakan | base | `NEEDS-COMPLIANCE-REVIEW` | Plafon setor tunai per transaksi; angka pilot pemilik 24 Okt 2026 (K-5). |
| `teller.cash.limit_opening_float` | kebijakan | base | `NEEDS-COMPLIANCE-REVIEW` | Plafon float laci per sesi; angka pilot pemilik 24 Okt 2026 (K-5). |
| `teller.cash.limit_withdrawal` | kebijakan | base | `NEEDS-COMPLIANCE-REVIEW` | Plafon tarik tunai per transaksi; angka pilot pemilik 24 Okt 2026 (K-5). |
| `teller.vault.cash_account` | kebijakan | base | `NEEDS-COMPLIANCE-REVIEW` | Pemetaan pilot `101.1 KAS DI VAULT` (memo T-118 §5, O-097/K-6) — bukan kutipan SAK EP/PSAK. |
| `teller.vault.limit_topup_per_request` | kebijakan | base | `NEEDS-COMPLIANCE-REVIEW` | Plafon satu pengajuan top-up vault; angka pilot pemilik 24 Okt 2026 (K-5). |

## Ringkasan per kelas

| kelas | jumlah definisi |
|---|---|
| teknis | 19 |
| kebijakan | 30 |
| komersial-konservatif | 2 |
| belum-bermakna | 0 |
| regulasi-tidak-disemai | 5 |
