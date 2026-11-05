<!-- GENERATED FILE: do not edit by hand. -->
<!-- Source: modules/*/migrations/*.sql + ops/migrations/contract-auto.txt -->
<!-- Regenerate: python3 tools/docsgen/docsgen.py schema -->
<!-- Drift check: python3 tools/docsgen/docsgen.py schema --check -->

# Schema inventory

Every module owns one PostgreSQL schema and evolves it through numbered migrations
(expand-only; contract migrations are separate). This page reflects **all migration
files in the repository**, including contract migrations that deploy runs only when
listed in `ops/migrations/contract-auto.txt`.

- Schemas: **9**; tables: **63**.
- Migration files: **134** (35 create at least one table, 99 do not).
- Tables with a `COMMENT ON TABLE` purpose: **54** of 63.
- Contract migrations declared for automatic deploy: **12**.

Counts are worst-case declarations after replaying every migration in filename order.
`unique` also counts `CREATE UNIQUE INDEX`, because both enforce uniqueness.
`-` means the source states nothing; it is never a guess.

## Tables

| Schema | Table | Purpose | Key columns | PK/FK/UQ/CK | Invariant triggers | Latest migration |
|---|---|---|---|---|---|---|
| daycloser | `checkpoint` | Checkpoint per entitas untuk task idempoten PER_ENTITY (spec §11.4). Hanya boleh maju - dijaga repositori. | pk: scope_type, scope_id, task_id, entity_key | 1/0/0/1 | - | `0051_daycloser_schema.sql` |
| daycloser | `chunk` | Checkpoint per potongan kerja (spec §11.3). `range_start`/`range_end` metadata untuk audit/UI; task memilih datanya dari chunk_no. | pk: run_id, task_id, chunk_no; fk: run_id, task_id → daycloser.task(run_id, task_id) | 1/1/0/3 | - | `0051_daycloser_schema.sql` |
| daycloser | `run` | Satu eksekusi penutupan untuk satu business date & scope (spec §11.2). `summary_hash` = segel bukti hasil run. | pk: run_id | 1/0/1/7 | - | `0051_daycloser_schema.sql` |
| daycloser | `task` | State per task dalam satu run (spec §11.3). `error` menyimpan kode+pesan diagnostik, bukan teks UI. | pk: run_id, task_id; fk: run_id → daycloser.run(run_id) | 1/1/0/3 | - | `0062_daycloser_task_reason.sql` |
| daycloser | `task_registry` | Salinan registry task saat boot (spec §11.4) untuk UI & audit; kebenaran eksekusi tetap registry in-process. | pk: task_id | 1/0/0/4 | - | `0051_daycloser_schema.sql` |
| deposit | `account` | Rekening simpanan (T-088a): identitas + produk/versi yang dipin. Saldo ada di account_balance; satu cabang per rekening (branch_id), tanpa FK karena belum ada tabel cabang. | pk: account_id; fk: party_id → party.party(party_id); fk: product_id → product.product(product_id); fk: product_version_id → product.product_version(version_id) | 1/3/1/5 | - | `0075_deposit_drop_last_activity.sql (contract, auto)` |
| deposit | `account_balance` | Cache saldo satu baris per rekening (T-088a). CHECK balance >= 0 = backstop DB; operasi yang menolak saldo negatif ada di jalur tulis (T-088b). Angka disimpan numeric(24,2), tanpa float. | pk: account_id; fk: account_id → deposit.account(account_id) | 1/1/0/1 | - | `0038_money_scale_2.sql` |
| deposit | `interest_accrual` | Akrual bunga deposito berjangka per tanggal buku (T-138c). PK (account_id, business_date) = idempotensi; amount = bagian yang dijurnal hari itu, cumulative = total yang dibulatkan sekali dari opened_on. Baris tanpa journal_id berarti… | pk: account_id, business_date; fk: account_id → deposit.account(account_id) | 1/1/0/7 | - | `0066_deposit_interest_accrual.sql` |
| deposit | `transaction` | Transaksi subledger simpanan (T-088b, T-138d): satu baris = satu jurnal per rekening (UNIQUE (journal_id, account_id); satu jurnal boleh mencatat dua rekening untuk perpindahan jatuh tempo). Nominal numeric(24,2) > 0; tanpa float. Koreksi… | pk: transaction_id; fk: account_id → deposit.account(account_id); fk: journal_id → ledger.journal(journal_id) | 1/2/1/3 | `deposit_transaction_immutable`, `deposit_transaction_no_truncate` | `0100_deposit_loan_recovery_type.sql (contract, auto)` |
| deposit | `transfer` | Pemindahbukuan antar rekening simpanan (T-088c): sumber & tujuan berbeda, satu jurnal per baris (sinkron, bukan outbox). Nominal numeric(24,2) > 0; tanpa float. Koreksi = jurnal pembalik, bukan ubah/hapus baris. | pk: transfer_id; fk: source_account_id → deposit.account(account_id); fk: destination_account_id → deposit.account(account_id); fk: journal_id → ledger.journal(journal_id) | 1/3/1/3 | `deposit_transfer_immutable`, `deposit_transfer_no_truncate` | `0038_money_scale_2.sql` |
| ledger | `balance_snapshot` | Cache saldo per akun per tanggal (T-075). Sumber kebenaran = journal_line; rekonstruksi lewat ledger.rebuild_balance_snapshot(as_of). | pk: account_code, as_of; fk: account_code → ledger.coa_account(code) | 1/1/0/3 | - | `0039_money_scale_2.sql` |
| ledger | `coa_account` | Chart of Accounts (T-072). Format kode = parameter ledger.coa.code_pattern; normal_side diturunkan dari account_type dan dijaga CHECK. Akun header/induk: postable = false. | pk: account_id | 1/0/1/6 | - | `0001_ledger_init.sql` |
| ledger | `journal` | Jurnal immutable (T-073). UPDATE/DELETE ditolak trigger; koreksi = jurnal pembalik. idempotency_key unik mencegah posting ganda dari event yang sama. | pk: journal_id; fk: reversal_of → ledger.journal(journal_id) | 1/1/2/3 | `journal_immutable`, `journal_no_truncate`, `journal_period_open` | `0072_ledger_journal_daycloser_origin.sql` |
| ledger | `journal_line` | Baris jurnal (T-073). Tepat satu sisi > 0 per baris; total debit = total kredit per jurnal (constraint trigger deferred). | pk: journal_id, line_no; fk: journal_id → ledger.journal(journal_id); fk: gl_account → ledger.coa_account(code) | 1/2/0/4 | `journal_line_account_postable`, `journal_line_immutable`, `journal_line_no_truncate`, `journal_line_same_transaction` | `0047_ledger_line_gl_index.sql` |
| ledger | `period` | Periode akuntansi (T-072), rentang inklusif. Tumpang tindih ditolak EXCLUDE; urutan tutup diatur daycloser (Fase 5), bukan constraint di sini. | pk: period_id | 1/0/0/3 | `period_guard` | `0060_ledger_period_system_close.sql (contract, auto)` |
| ledger | `posting_rule` | Aturan jurnal per event. `LoanDisbursed` (T-164): D 110 Piutang Pembiayaan / K 201 Simpanan Anggota - nilai akun adalah data yang bisa diganti, bukan konstanta kode. | pk: rule_id | 1/0/0/3 | - | `0083_ledger_posting_rules_loan.sql` |
| ledger | `posting_rule_line` | Template baris posting rule (T-074). Fase 1: tepat satu DEBIT + satu CREDIT per rule. | pk: rule_id, line_no; fk: rule_id → ledger.posting_rule(rule_id); fk: gl_account → ledger.coa_account(code) | 1/2/0/2 | - | `0004_ledger_posting_rule.sql` |
| lending | `collectibility_snapshot` | Penilaian kolektibilitas per tanggal buku (T-166). Primary key (loan_id, business_date) = idempotensi task day-close; nilai historis dipakai PPAP (T-167). | pk: loan_id, business_date; fk: loan_id → lending.loan(loan_id) | 1/1/0/2 | - | `0090_lending_collectibility.sql` |
| lending | `installment` | Jadwal angsuran (T-161): satu baris per jatuh tempo, dibekukan setelah dibayar. | pk: loan_id, no; fk: loan_id → lending.loan(loan_id) | 1/1/0/12 | `lending_installment_immutable` | `0093_lending_restructure.sql` |
| lending | `loan` | Akad pinjaman (T-161): syarat dibekukan lewat product_version_id. Saldo ada di loan_balance. | pk: loan_id; fk: party_id → party.party(party_id); fk: product_version_id → lending.loan_product_version(version_id) | 1/2/0/10 | - | `0101_lending_restructure_grade.sql` |
| lending | `loan_balance` | Cache saldo pinjaman (T-161); sumber kebenaran jadwal + jurnal. CHECK >= 0 adalah backstop. | pk: loan_id; fk: loan_id → lending.loan(loan_id) | 1/1/0/3 | - | `0078_lending_loan.sql` |
| lending | `loan_product` | - | pk: product_id | 1/0/1/2 | - | `0077_lending_loan_product.sql` |
| lending | `loan_product_version` | - | pk: version_id; fk: product_id → lending.loan_product(product_id) | 1/1/1/7 | `lending_loan_product_version_immutable` | `0077_lending_loan_product.sql` |
| lending | `loan_schedule` | Versi jadwal pinjaman (T-168). Versi 1 = jadwal pencairan; versi berikutnya = restrukturisasi, dengan alasan dan pelakunya. Baris jadwal lama ditandai `superseded_on`, tidak dihapus. | pk: loan_id, version_no; fk: loan_id → lending.loan(loan_id) | 1/1/0/2 | - | `0093_lending_restructure.sql` |
| lending | `payment` | Pembayaran angsuran (T-165): satu baris per peristiwa bayar, dengan rincian komponen yang jumlahnya tepat sama dengan nominal. | pk: payment_id; fk: loan_id → lending.loan(loan_id); fk: account_id → deposit.account(account_id) | 1/2/0/5 | - | `0085_lending_payment.sql` |
| lending | `payment_allocation` | Alokasi pembayaran ke baris jadwal (T-165): menutup baris ke berapa, komponen apa, berapa. | pk: payment_id, installment_no, component; fk: payment_id → lending.payment(payment_id) | 1/1/0/3 | - | `0085_lending_payment.sql` |
| lending | `ppap_snapshot` | Penyisihan PPAP per pinjaman per tanggal buku (T-167). PK (loan_id, business_date) = idempotensi task; selisih terhadap tanggal buku sebelumnya yang dijurnal. | pk: loan_id, business_date; fk: loan_id → lending.loan(loan_id) | 1/1/0/4 | - | `0091_lending_ppap.sql` |
| lending | `recovery` | - | pk: recovery_id; fk: loan_id → lending.loan(loan_id) | 1/1/0/6 | - | `0098_lending_recovery.sql` |
| lending | `writeoff` | Hapus buku (T-168): nilai piutang yang dihapus, berapa ditutup penyisihan (111) dan berapa menjadi beban (504). Satu baris per pinjaman - hapus buku hanya sekali. | pk: loan_id; fk: loan_id → lending.loan(loan_id) | 1/1/0/6 | - | `0094_lending_writeoff.sql` |
| party | `address` | Alamat party (T-078): baris alamat, kota, kode pos - tiap kolom ciphertext+blind index+bentuk tersamar (pola D-069). Belum ada alamat ganda (1:1) sampai kebutuhan 1:N muncul. | pk: address_id; fk: party_id → party.party(party_id) | 1/1/1/9 | - | `0041_party_detail.sql` |
| party | `identity_doc` | Dokumen identitas party (T-071). number_enc = ciphertext field crypto (AAD identity_doc); number_bidx = blind index untuk duplikat; number_last2 = bentuk tersamar untuk UI. | pk: doc_id; fk: party_id → party.party(party_id) | 1/1/1/5 | - | `0002_party_kyc.sql` |
| party | `kyc_profile` | Profil KYC per party (T-071): status, rating risiko berjalan, jadwal re-KYC. Nilai yang sah berasal dari parameter (party.kyc.risk_levels / review_months), bukan CHECK DB. | pk: party_id; fk: party_id → party.party(party_id) | 1/1/0/2 | - | `0002_party_kyc.sql` |
| party | `party` | - | pk: party_id | 1/0/1/4 | - | `0001_party_init.sql` |
| party | `party_org` | Detail PII lembaga per party (T-078): nama resmi. Pola penyimpanan sama dengan party.party_person (D-069). | pk: party_id; fk: party_id → party.party(party_id) | 1/1/0/3 | - | `0041_party_detail.sql` |
| party | `party_person` | Detail PII orang per party (T-078). Tiap field disimpan ciphertext+blind index+bentuk tersamar (pola D-069); nilai aslinya tidak pernah plaintext. Kriptografi dibuat composition root (apps/api), bukan modul. | pk: party_id; fk: party_id → party.party(party_id) | 1/1/0/12 | - | `0041_party_detail.sql` |
| party | `risk_rating` | Riwayat penilaian risiko (append-only, T-071). Level berjalan = baris terbaru dan dicerminkan di party.kyc_profile. Penilaian manual oleh petugas; skor otomatis bukan lingkup task ini. | pk: rating_id; fk: party_id → party.party(party_id) | 1/1/0/2 | `risk_rating_immutable` | `0002_party_kyc.sql` |
| platform | `app_user` | Pengguna sistem (spec §9.2 `user`). Username wajib lower-case; lockout dijaga kolom status + locked_until. | pk: user_id | 1/0/1/3 | - | `0006_platform_auth.sql` |
| platform | `audit_log` | Append-only + hash chain (tamper-evident). Verifikasi: SELECT * FROM platform.audit_verify(). | pk: seq | 1/0/2/0 | `audit_log_chain_trg`, `audit_log_no_change_trg`, `audit_log_no_purge_trg` | `0049_platform_audit_prev_hash_unique.sql` |
| platform | `branch` | Master cabang (D-135): kode 3 digit = prefiks nomor rekening. Modul lain tetap menyimpan branch_id tanpa FK (expand-only). | pk: branch_id | 1/0/1/3 | - | `0030_platform_branch_master.sql` |
| platform | `business_date` | Tanggal buku sistem per scope (spec §9.3, §11.2). Transisi sah hanya OPEN → CLOSING → CLOSED; rollover mengubah current_business_date pada baris CLOSED (bukan reopen). | - | 0/0/1/3 | - | `0005_platform_calendar.sql` |
| platform | `holiday` | Hari libur kalender (spec §9.2). `name_key` = kunci i18n (tidak ada teks hardcode); recurring_annual = berulang setiap tahun pada bulan/tanggal yang sama. | pk: holiday_id | 1/0/1/3 | - | `0005_platform_calendar.sql` |
| platform | `idempotency_key` | Klaim Idempotency-Key per principal (D-098). Ditulis dalam transaksi bisnis; replay hanya 2xx. | pk: principal_id, key; fk: principal_id → platform.app_user(user_id) | 1/1/0/7 | - | `0021_platform_idempotency.sql` |
| platform | `inbox` | De-dup per konsumen: INSERT ... ON CONFLICT DO NOTHING; 0 baris = sudah pernah diproses. | pk: consumer, event_id | 1/0/0/0 | - | `0003_platform_outbox_inbox.sql` |
| platform | `outbox` | Transactional outbox: ditulis satu transaksi dengan perubahan state; dispatcher memakai FOR UPDATE SKIP LOCKED. | pk: outbox_id | 1/0/2/1 | `outbox_notify_insert` | `0007_platform_outbox_notify.sql` |
| platform | `param_definition` | Definisi parameter (skema + governance). Diisi seed dari modules/<m>/seeds/params.yaml via tools/paramgen. | pk: key | 1/0/0/3 | - | `0004_platform_parameter.sql` |
| platform | `param_end_request` | Pengajuan pengakhiran nilai parameter (O-064): PENDING → APPROVED/REJECTED oleh akun lain; persetujuan memangkas platform.param_value.effective_to tanpa menuntut nilai penerus. | pk: request_id; fk: param_value_id → platform.param_value(param_value_id) | 1/1/1/4 | - | `0103_platform_param_end_request.sql` |
| platform | `param_value` | Nilai parameter effective-dated + maker-checker. Hanya satu ACTIVE per (key, scope, periode); SUPERSEDED menyimpan riwayat. | pk: param_value_id; fk: key → platform.param_definition(key) | 1/1/0/7 | - | `0004_platform_parameter.sql` |
| platform | `permission` | - | pk: permission_id | 1/0/1/1 | - | `0006_platform_auth.sql` |
| platform | `role` | - | pk: role_id | 1/0/1/2 | - | `0028_platform_rbac_role_scope.sql` |
| platform | `role_conflict` | Matriks pemisahan tugas (SoD, spec §18.2): pasangan role yang tidak boleh dipegang satu orang. Pasangan kanonik satu arah (a < b). Isi matriks = kebijakan institusi, tidak disemai di repo. | pk: role_code_a, role_code_b; fk: role_code_a → platform.role(code); fk: role_code_b → platform.role(code) | 1/2/0/1 | - | `0006_platform_auth.sql` |
| platform | `role_permission` | - | pk: role_id, permission_id; fk: role_id → platform.role(role_id); fk: permission_id → platform.permission(permission_id) | 1/2/0/0 | - | `0006_platform_auth.sql` |
| platform | `session` | - | pk: session_id; fk: user_id → platform.app_user(user_id) | 1/1/1/1 | - | `0100_platform_session_mfa_pending.sql` |
| platform | `user_mfa` | Faktor kedua TOTP per akun (spec §13). secret_enc = ciphertext field crypto (AAD user_mfa); digits/period disimpan per baris supaya perubahan parameter tidak membatalkan rahasia lama. | pk: user_id; fk: user_id → platform.app_user(user_id) | 1/1/0/5 | - | `0044_platform_mfa_secret_enc_check.sql` |
| platform | `user_password_history` | Hash kata sandi yang sudah digantikan, urut `seq` (terbaru terbesar). Dipangkas ke N terakhir; N dari parameter platform.security.password_history_count. | pk: seq; fk: user_id → platform.app_user(user_id) | 1/1/0/0 | - | `0010_platform_password_history.sql` |
| platform | `user_role` | - | fk: user_id → platform.app_user(user_id); fk: role_id → platform.role(role_id) | 0/2/1/0 | - | `0006_platform_auth.sql` |
| platform | `worker_heartbeat` | Denyut proses worker (O-081). Satu baris per worker terakhir melapor; dibaca /readyz, bukan sumber kebenaran bisnis. | pk: worker_name | 1/0/0/0 | - | `0019_platform_worker_heartbeat.sql` |
| product | `product` | Katalog produk (T-076). Identitas produk stabil; atribut berubah lewat versi baru, bukan edit. | pk: product_id | 1/0/1/4 | `product_guard_savings_kind`, `product_guard_update` | `0007_product_savings_kind.sql` |
| product | `product_param_binding` | Nilai atribut produk per versi (T-076). Kunci harus parameter terdaftar; tipenya divalidasi composition root. Binding dibekukan saat versi sealed. | pk: version_id, param_key; fk: version_id → product.product_version(version_id) | 1/1/0/1 | `product_binding_open`, `product_param_binding_immutable`, `product_param_binding_no_truncate` | `0002_product_catalog.sql` |
| product | `product_version` | Versi produk effective-dated (T-076). Rentang inklusif [from, to]; EXCLUDE menolak tumpang tindih. Versi immutable kecuali effective_to (diisi sekali) dan transisi sealed false→true. | pk: version_id; fk: product_id → product.product(product_id) | 1/1/1/5 | `product_version_guard_insert`, `product_version_guard_update` | `0006_product_version_contract.sql (contract, auto)` |
| teller | `cash_movement` | Arus kas laci per sesi (T-093): CASH_IN (setoran masuk laci) / CASH_OUT (penarikan keluar laci). Setiap baris menunjuk tepat satu `deposit.transaction` (FK + UNIQUE) yang ditulis di transaksi DB yang sama; tanpa ini `expected_cash` bisa… | pk: movement_id; fk: session_id → teller.teller_session(session_id); fk: transaction_id → deposit.transaction(transaction_id) | 1/2/1/2 | `teller_cash_movement_immutable`, `teller_cash_movement_no_truncate` | `0040_money_scale_2.sql` |
| teller | `teller_session` | Sesi kas teller (T-093): satu sesi OPEN per (cabang, teller) dijaga partial unique index. opening_float masuk dari vault saat buka; expected_cash = opening_float + Σ CASH_IN − Σ CASH_OUT dihitung saat tutup; variance = counted_cash −… | pk: session_id; fk: teller_user_id → platform.app_user(user_id); fk: opened_by → platform.app_user(user_id); fk: closed_by → platform.app_user(user_id) | 1/3/1/5 | - | `0040_money_scale_2.sql` |
| teller | `vault` | Saldo kas fisik satu vault per cabang (T-093). Bertambah saat sesi ditutup (counted cash) dan berkurang saat sesi dibuka (opening float). CHECK balance >= 0 = backstop DB; operasi yang menolak saldo kurang ada di jalur tulis. Angka… | pk: branch_id | 1/0/0/1 | - | `0040_money_scale_2.sql` |
| teller | `vault_topup_request` | Pengajuan top-up vault (T-118): PENDING → APPROVED/REJECTED oleh akun lain; persetujuan menulis saldo vault + jurnal D 101.1 / K source_account dalam satu transaksi. | pk: request_id; fk: source_account → ledger.coa_account(code) | 1/1/1/6 | - | `0043_teller_vault_topup_journal_fk.sql` |

## Schemas

| Schema | Tables |
|---|---|
| daycloser | 5 |
| deposit | 5 |
| hello | 0 |
| ledger | 7 |
| lending | 12 |
| party | 7 |
| platform | 20 |
| product | 3 |
| teller | 4 |

## Contract migrations

These files change or remove existing objects and are executed automatically by
deploy only because they are listed in `ops/migrations/contract-auto.txt`.

| Contract id | File | Tables touched |
|---|---|---|
| `product/0004_product_version_contract` | `modules/product/migrations/0004_product_version_contract.sql` | `product.product_version` |
| `product/0006_product_version_contract` | `modules/product/migrations/0006_product_version_contract.sql` | `product.product_version` |
| `ledger/0060_ledger_period_system_close` | `modules/ledger/migrations/0060_ledger_period_system_close.sql` | `ledger.period` |
| `deposit/0064_deposit_time_deposit` | `modules/deposit/migrations/0064_deposit_time_deposit.sql` | `deposit.account` |
| `deposit/0068_deposit_transaction_maturity` | `modules/deposit/migrations/0068_deposit_transaction_maturity.sql` | `deposit.transaction` |
| `deposit/0071_deposit_account_dormant_status` | `modules/deposit/migrations/0071_deposit_account_dormant_status.sql` | `deposit.account` |
| `deposit/0072_deposit_account_last_activity_comment` | `modules/deposit/migrations/0072_deposit_account_last_activity_comment.sql` | `deposit.account` |
| `deposit/0074_deposit_early_withdrawal_transfer_types` | `modules/deposit/migrations/0074_deposit_early_withdrawal_transfer_types.sql` | `deposit.transaction` |
| `deposit/0075_deposit_drop_last_activity` | `modules/deposit/migrations/0075_deposit_drop_last_activity.sql` | `deposit.account` |
| `deposit/0082_deposit_loan_disbursement_type` | `modules/deposit/migrations/0082_deposit_loan_disbursement_type.sql` | `deposit.transaction` |
| `deposit/0086_deposit_loan_payment_type` | `modules/deposit/migrations/0086_deposit_loan_payment_type.sql` | `deposit.transaction` |
| `deposit/0100_deposit_loan_recovery_type` | `modules/deposit/migrations/0100_deposit_loan_recovery_type.sql` | `deposit.transaction` |

## Migrations without table creation

ALTER/COMMENT/trigger/grant-only migrations still change the schema above; they are
listed here so no migration file disappears from the inventory. `DDL recorded`
counts the statements by kind.

| Migration | DDL recorded |
|---|---|
| `0001_deposit_schema.sql` | create schema (1), sequence (1) |
| `0001_hello_init.sql` | create schema (1) |
| `0001_platform_schema.sql` | comment (1), create schema (1) |
| `0001_product_init.sql` | create schema (1) |
| `0001_teller_schema.sql` | create schema (1) |
| `0002_ledger_coa_base.sql` | insert (1) |
| `0003_product_version_approval.sql` | alter table (2), comment (2), function (4), index (1), other (1), trigger (1) |
| `0004_product_version_contract.sql` | alter table (1), drop (1), drop trigger (1) |
| `0005_deposit_transaction_immutable.sql` | trigger (2) |
| `0005_ledger_posting_rule_base.sql` | insert (2) |
| `0005_product_deprecate_grace.sql` | other (1) |
| `0006_deposit_runtime_grants.sql` | do block (1) |
| `0006_ledger_journal_guards.sql` | comment (1), function (2), index (1), other (1) |
| `0006_product_version_contract.sql` | alter table (1), drop (1), drop trigger (1), function (1), trigger (1) |
| `0007_platform_outbox_notify.sql` | comment (1), function (1), trigger (1) |
| `0007_product_savings_kind.sql` | alter table (2), comment (1), function (1), trigger (1) |
| `0007_teller_runtime_grants.sql` | do block (1) |
| `0008_deposit_transfer_grants.sql` | do block (1) |
| `0008_ledger_journal_line_same_tx.sql` | function (1), trigger (1) |
| `0008_platform_rbac_catalogue.sql` | insert (4) |
| `0009_ledger_snapshot_asof_index.sql` | index (1) |
| `0009_platform_outbox_channel_kran.sql` | comment (1), function (1) |
| `0010_ledger_journal_xmin_epoch.sql` | comment (1), function (1) |
| `0011_ledger_period_lock.sql` | comment (1), function (1) |
| `0011_platform_audit_verify_prev_hash.sql` | function (1), index (2) |
| `0012_ledger_posting_rules_deposit.sql` | insert (2) |
| `0013_ledger_posting_rules_transfer.sql` | insert (2) |
| `0013_platform_rbac_party.sql` | insert (2) |
| `0014_ledger_coop_savings.sql` | insert (3) |
| `0014_platform_rbac_party_pii.sql` | insert (2) |
| `0015_platform_rbac_ledger.sql` | insert (2) |
| `0016_platform_rbac_ledger_journal.sql` | insert (2) |
| `0017_platform_rbac_product.sql` | insert (2) |
| `0018_platform_rbac_product_grants.sql` | insert (1) |
| `0020_platform_sod_param_conflict.sql` | insert (1) |
| `0022_platform_rbac_product_approve.sql` | insert (2) |
| `0023_platform_rbac_deposit.sql` | insert (2) |
| `0024_platform_rbac_teller.sql` | insert (2) |
| `0025_platform_rbac_teller_session.sql` | insert (2) |
| `0026_platform_rbac_teller_vault.sql` | insert (2) |
| `0027_platform_rbac_pilot_roles.sql` | insert (3) |
| `0028_platform_rbac_role_scope.sql` | alter table (1), comment (1), insert (1), other (1) |
| `0029_platform_rbac_user_admin.sql` | insert (2) |
| `0031_deposit_account_number_branch_code.sql` | comment (1), do block (1) |
| `0032_platform_rbac_admin_roles.sql` | insert (6) |
| `0033_ledger_cash_clearing.sql` | insert (1), other (2) |
| `0034_ledger_posting_rules_teller_cash.sql` | insert (2) |
| `0036_ledger_vault_opening_balance.sql` | insert (3) |
| `0037_platform_branch_read.sql` | insert (2) |
| `0038_money_scale_2.sql` | alter table (3), comment (3), do block (1) |
| `0039_money_scale_2.sql` | alter table (2), do block (2), function (1) |
| `0040_money_scale_2.sql` | alter table (4), comment (1), do block (1) |
| `0042_platform_runtime_privileges.sql` | do block (1) |
| `0043_teller_vault_topup_journal_fk.sql` | alter table (1), do block (1), index (1) |
| `0044_platform_mfa_secret_enc_check.sql` | alter table (1), do block (1) |
| `0045_ledger_period_immutable.sql` | comment (1), function (1), trigger (1) |
| `0046_ledger_money_range.sql` | do block (1) |
| `0047_ledger_line_gl_index.sql` | index (1) |
| `0048_platform_audit_action_index.sql` | index (1) |
| `0049_platform_audit_prev_hash_unique.sql` | index (1) |
| `0050_platform_audit_chain_tail.sql` | function (1) |
| `0060_ledger_period_system_close.sql` | alter table (3), comment (2) |
| `0061_platform_rbac_dayclose.sql` | insert (2) |
| `0062_daycloser_task_reason.sql` | alter table (1), comment (1) |
| `0063_platform_rbac_dayclose_manage.sql` | insert (2) |
| `0064_deposit_time_deposit.sql` | alter table (2), comment (4) |
| `0065_ledger_interest_accrual.sql` | insert (3) |
| `0067_ledger_posting_rules_time_deposit.sql` | insert (2) |
| `0068_deposit_transaction_maturity.sql` | alter table (2), comment (2) |
| `0069_ledger_posting_rules_maturity.sql` | insert (2) |
| `0070_deposit_interest_accrual_grant.sql` | do block (1) |
| `0071_deposit_account_dormant_status.sql` | alter table (1), comment (1) |
| `0072_deposit_account_last_activity_comment.sql` | comment (1) |
| `0072_ledger_journal_daycloser_origin.sql` | alter table (1), comment (1), index (1) |
| `0073_deposit_account_interest_paid.sql` | alter table (1), comment (1) |
| `0073_ledger_early_withdrawal.sql` | insert (3) |
| `0074_deposit_early_withdrawal_transfer_types.sql` | alter table (1), comment (1) |
| `0074_ledger_early_withdrawal_transfer.sql` | insert (2) |
| `0075_deposit_drop_last_activity.sql` | alter table (1) |
| `0075_platform_rbac_teller_branch_read.sql` | insert (1) |
| `0076_lending_schema.sql` | create schema (1) |
| `0080_lending_runtime_grants.sql` | do block (1) |
| `0081_platform_rbac_lending.sql` | insert (7) |
| `0082_deposit_loan_disbursement_type.sql` | alter table (1), comment (1) |
| `0083_ledger_posting_rules_loan.sql` | comment (1), insert (2) |
| `0084_platform_rbac_lending_disburse.sql` | insert (2) |
| `0086_deposit_loan_payment_type.sql` | alter table (1), comment (1) |
| `0087_ledger_posting_rules_loan_payment.sql` | insert (3) |
| `0088_platform_rbac_lending_pay.sql` | insert (2) |
| `0089_lending_installment_paid_update.sql` | function (1) |
| `0092_ledger_coa_ppap.sql` | insert (3) |
| `0095_ledger_coa_writeoff.sql` | insert (3) |
| `0096_platform_rbac_lending_restructure.sql` | insert (3) |
| `0097_ledger_coa_loan_recovery.sql` | insert (3) |
| `0099_platform_rbac_lending_recovery.sql` | insert (2) |
| `0100_deposit_loan_recovery_type.sql` | alter table (1) |
| `0100_platform_session_mfa_pending.sql` | alter table (1), comment (1) |
| `0101_lending_restructure_grade.sql` | alter table (2), comment (3) |
| `0102_lending_runtime_grants_transactional.sql` | do block (1) |
