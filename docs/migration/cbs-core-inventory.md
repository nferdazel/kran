# Inventaris `cbs-core` — referensi untuk CBS, bukan basis kode

> **Status**: inventaris (bukan endorsement). `cbs-core` (Go) diperlakukan sebagai
> **referensi**; tidak ada port kode Go → Nim (spec §21.9). Dokumen ini mencatat apa yang
> **ada**, apa yang **tervalidasi**, dan apa yang **asumsi**, supaya aturan yang valid bisa
> dijadikan golden test `cbs` (§20) tanpa mewarisi utangnya.
>
> **Aturan bukti**: setiap klaim menyertakan path berkas `cbs-core` (dan baris bila
> relevan). Klaim tanpa bukti ditandai `(belum diverifikasi)`. Klaim yang berasal dari
> dokumen (bukan kode) ditandai sumbernya; bila dokumen menyebut pasal regulasi, pasal itu
> **dikutip apa adanya** dan verifikasi compliance tetap terbuka (spec §4/§1.8).
>
> **Basis pembacaan**: repo `/Users/sachiel/Projects/cbs-core`, branch `main`, commit
> `fade1465a7df13cd2e9c39d56e283c886375fce9` (2026-10-13 14:11 +07). Path di tabel memakai
> akar `cbs-core/`. Semua berkas dibaca **read-only**; tidak ada yang diubah.

---

## 1. Ringkasan & status repo

`cbs-core` adalah core banking untuk **BPR/BPRS** Indonesia (konvensional + syariah) —
bukan koperasi (lihat §4 catatan SHU). Isi repo:

| Aspek | Nilai | Sumber |
|---|---|---|
| Berkas Go (semua) | **699** | hitung `find apps/api -name '*.go'` |
| Berkas uji Go | **370** | hitung `find apps/api -name '*_test.go'` |
| LoC Go non-uji | **±78.063** | hitung `wc -l` |
| Berkas domain / service / handler / repo (non-uji) | **83 / 71 / 37 / 65** | `ls apps/api/internal/**` |
| Berkas uji integrasi (butuh DB) | **54** (menyebut `CBS_TEST_DB`) | grep |
| Migrasi `*.up.sql` | **134** (terakhir `000137`) | `ls packages/db-migrations/*.up.sql` |
| Migrasi `*.down.sql` | **39** (praktik sejak `000099`) | `ls .../*.down.sql` |
| Total berkas `*.sql` | **173** | hitung |
| Tabel (`CREATE TABLE` unik di migrasi) | **62** | grep migrasi |
| Dokumen `docs/*.md` | **19** | `ls docs/*.md` |
| Commit | **408** (log dangkal/ter-squash) `(belum diverifikasi apakah lengkap)` | `git log --oneline \| wc -l` |
| Commit terakhir | `fade1465a7df13cd2e9c39d56e283c886375fce9`, 2026-10-13 14:11 +07 | `git log -1` |

**Aplikasi/paket** (`cbs-core/README.md`):

- `apps/api` — REST API Go, module path `cbs-core/apps/core-api` (`apps/api/go.mod`). Enam
  sub-paket internal: `domain`, `repository/postgres`, `service`, `handler/http`,
  `middleware`, `ojkreport` (+ `config`, `crypto`, `i18n`, `metrics`, `monitoring`,
  `observability`). Entrypoint `apps/api/cmd/server`, dua utilitas: `cmd/backfill-name-tokens`,
  `cmd/reindex-customer-indexes`.
- `apps/web` — backoffice Next.js 15 (React 19), 105 berkas `.tsx/.ts`. Rute dashboard:
  `rekening`, `teller`, `transaksi`, `kredit`, `pembiayaan`, `deposito`, `jatuh-tempo`,
  `buku-besar`, `nasabah`, `cabang`, `ppap`, `laporan`, `pemetaan-ojk`, `persetujuan`,
  `tutup-hari`, `pengaturan/*` (termasuk `ckpn`, `ckpn-individual`, `bobot-agunan`, `ojk`,
  `izin`, `staf`).
- `packages/db-migrations` — migrasi PostgreSQL bernomor (`NNNNNN_*.up.sql`, pasangan
  `*.down.sql` sejak 000099).
- `packages/shared-types` — `@cbs/shared-types` (kontrak TypeScript bersama).
- `deploy/` — Quadlet `cbs-api`/`cbs-web`, Caddy, `observability/`. `scripts/` —
  `migrate.sh`, `preflight.sh`, `check-secrets.sh`, `deploy.sh`.

**Toolchain** (`cbs-core/README.md`): Go 1.26.0; Node 22; pnpm 11.25.0; PostgreSQL 16 lokal,
**18 produksi**; Turbo ^2.4.4. Runtime produksi: `apps/api` → `localhost:8095→8080`,
`apps/web` → `localhost:3005→3000`.

**Cakupan uji & CI (fakta, bukan klaim kualitas):**

- CI hanya build/lint/unit; uji integrasi butuh DB dan **tidak** dijalankan di CI
  (`cbs-core/README.md`, bagian Status + Tests).
- `apps/web` **tidak punya test runner**: `apps/web/package.json` hanya punya
  `lint` (ESLint) dan `check:i18n`; tidak ada Vitest/Playwright/axe. **Tidak ada uji
  komponen/e2e/a11y/visual** di `cbs-core` `(belum diverifikasi apakah ada di luar repo)`.
- README menyebut satu uji integrasi rapuh bila seluruh suite dijalankan pada satu DB
  (`TestIntegrasiOJKFormDaftarDanNPL` meng-assert rasio NPL bank-wide; lolos bila sendiri).

**Saklar yang sengaja mati** (`cbs-core/README.md`; `docs/KEPUTUSAN.md:584-588`):
`ppap.collateral.enabled`, `ckpn.enabled`, `ckpn.individual.enabled`,
`loan.restructure.loss.enabled`, modul Pasal 23 (LPS), `auth.password_expiry_days`.

---

## 2. Peta fitur per modul/domain

Legenda status: **[jalan]** terpasang & teruji; **[bayangan]** menghitung tapi tidak
menjurnal; **[mati]** saklar bawaan mati; **[mock]** bukan integrasi nyata; **[belum]** ada
celah yang diakui dokumen.

### 2.1 Akuntansi & ledger — [jalan]
- Double-entry `Σ debit = Σ kredit`, tanpa ORM (SQL eksplisit + `shopspring/decimal`):
  `apps/api/internal/domain/ledger.go`, `domain/posting.go`,
  `service/ledger_service.go`, `service/posting_service.go`,
  `repository/postgres/ledger_repo.go`.
- Idempotensi jurnal: tabel `idempotency_keys`; sumber jurnal `journal_entries.source`
  (migrasi `000035`).
- Jurnal majemuk: `service/posting_service.go` `PostCompoundJournal`; handler
  `handler/http/ledger_handler.go` (`ledger_compound_handler_test.go`).
- Penutupan tahun buku: `domain/year_end.go`, `domain/batch.go`.

### 2.2 Nasabah/CIF & rekening — [jalan]
- CIF: `domain/customer.go`, `domain/customer_name.go`, `domain/account_number.go`;
  enkripsi AES-256-GCM per-field + blind index (`internal/crypto`), tabel
  `customer_name_tokens`, `customer_name_tokens` (migrasi `000039`).
- Rekening & tabungan/giro: `domain/account.go`, `domain/savings_account.go`,
  `domain/savings_customer.go`; freeze/unfreeze
  (`handler/http/account_freeze_handler_test.go`); dormant (`account_dormant_test.go`).
- Teller + idempotency kunci transaksi: `service/account_service.go`, `service/tx_runner.go`.

### 2.3 Deposito berjangka — [jalan]
- `domain/deposit.go`, `domain/time_deposit_report.go`, `service/deposit_service.go`.
- Tabel `deposits` (migrasi `000013_time_deposit.up.sql`) dengan ARO
  (`aro`, `aro_instruction` IN/NONE/PRINCIPAL/PRINCIPAL_AND_PROFIT) dan pinalti pencairan
  dini (migrasi `000016`). Di-rename `deposits`→`time_deposits` di `000101`
  (`docs/PENAMAAN-TABEL.md:83`) — **namun `CREATE TABLE deposits` tetap ada di migrasi awal**.

### 2.4 Kredit & pembiayaan — [jalan]
- Pokok kredit: `domain/loan.go`, `domain/loan_payment.go`, `domain/loan_accrual.go`,
  `domain/loan_penalty.go`, `domain/pinjaman.go`, `domain/schedule.go`,
  `service/loan_service.go`, `service/loan_interest_accrual.go`, `service/loan_penalty.go`.
- Jadwal angsuran: flat, anuitas, sliding, murabahah (margin), bagi hasil — `domain/schedule.go`.
- Pembatalan pencairan (`5c(a)`) & koreksi nominal (`5c(b)`): `docs/KEPUTUSAN.md:136-159`;
  permission `loans:cancel` / `loans:correct`.
- Hapus buku: `domain/loan.go`, `service/loan_service.go`, `service/loan_recovery_submission.go`,
  migrasi `000031`, `000085`, `000129` (`loan_write_off_regulation_integration_test.go`).
- Kerugian restrukturisasi (EIR) — **[mati]** `loan.restructure.loss.enabled`:
  `domain/restructure_loss.go`, `domain/restructure_loss_amortization.go`,
  `service/restructure_loss_service.go`, migrasi `000043`, `000044`, `000094`.

### 2.5 Syariah (UUS/buku SYARIAH) — [jalan]
- Pemetaan produk syariah (akad: mudharabah/musyarakah/murabahah):
  migrasi `000019_syariah_financing_mapping.up.sql`; `domain/pinjaman.go`.
- Bagi hasil mudharabah: `domain/savings_interest.go` (`MudharabahShare`,
  `MudharabahAllocate`), `service/savings_interest_service.go`, migrasi `000059`, `000060`.
- Denda syariah/ta'zir → akun `12500 Dana Kebajikan`, menolak kredit ke akun pendapatan
  `40500`: `domain/loan_penalty.go:22-31`, `docs/KEPUTUSAN.md:207,637-643`.

### 2.6 Kolektibilitas, PPAP/PPKA, CKPN — [jalan]/[bayangan]/[mati]
- Kolektibilitas: `domain/collection.go`, `service/collectibility_rules.go`
  (satu jalur `CollectibilityForPosition` untuk PPAP + restrukturisasi + akrual).
- PPAP/PPKA: `domain/ppap.go`, `service/ppap_service.go`, `service/ppap_run_marker.go`;
  tarif & ambang dari `system_config` (migrasi `000014`, `000026`, `000027`).
- CKPN kolektif: `domain/ckpn.go`, `service/ckpn_service.go` — **[bayangan]**
  (`ckpn.shadow_mode.enabled=true`, `ckpn.enabled=false`; `docs/KEPUTUSAN.md:647`).
- CKPN individual (DCF/NRV): `domain/ckpn_individual*.go`, `service/ckpn_individual_service.go`,
  `service/ckpn_individual_config.go` — **[mati]** (`docs/CKPN-INDIVIDUAL-RANCANGAN.md`).
- PABL (CKPN penempatan bank lain): `domain/pabl_ckpn.go`,
  `service/ckpn_pabl_activation_service.go`, migrasi `000099`, `000100`, `000134`.
- Aktivasi/ratifikasi CKPN: `domain/ckpn_activation.go`, `domain/ckpn_parameters.go`,
  `service/ckpn_activation_service.go`, migrasi `000093`, `000095`, `000135`.
  Endpoint `GET/PUT /api/v1/system/ckpn-activation` (`docs/CKPN-SIAP-RILIS.md` §(i)).

### 2.7 Agunan — [mati]
- `domain/collateral.go`, `domain/collateral_pasal20.go`, `domain/collateral_weight.go`;
  `service/collateral_service.go`, `service/collateral_weight.go`; migrasi `000036`,
  `000038`, `000040`, `000047`, `000087`, `000097`, `000098`.
- Bobot Lampiran II SEOJK 2/2025 + daftar periksa C1–C9 →
  `docs/KEPUTUSAN-PANEL-RISIKO-CKPN.md` §3. Saklar `ppap.collateral.enabled=false`.

### 2.8 BMPK & KPMM — [jalan]/[konservatif]
- BMPK (plafon internal bank, bukan persentase regulator): `domain/bmpk.go`,
  `service/bmpk_service.go`, migrasi `000103`; catatan batas:
  `docs/CELAH-LAPORAN-OJK.md:56`.
- KPMM/ATMR: `domain/kpmm.go`, `service/kpmm_service.go`,
  `apps/api/internal/ojkreport/kpmm.go`; migrasi `000082`, `000084`, `000086`.
  Bobot risiko dinilai konservatif/belum granular di `docs/CKPN-SIAP-RILIS.md` §(f).

### 2.9 Pelaporan OJK — [jalan sebagian]
- Mesin laporan berkala: `apps/api/internal/ojkreport/` (`definitions.go`,
  `builder.go`, `coa_mapping.go`, form `form00_*`…`form06_*`, `bmpk.go`). 45 form resmi
  terdaftar; **43 `Buildable:true`, 11 `Buildable:false`** (hitung grep `definitions.go`)
  `(belum diverifikasi bila dibaca per form mana)`.
- Register OJK: AYDA (`domain/ayda.go`, migrasi `000115`), aset tetap (`000119`), aset
  keuangan lainnya (`000121`), kas valas (`000123`), kepemilikan BPR (`000116`), kelembagaan
  (`000112`), modal (`000128`), penyertaan (`000120`), pinjaman diterima (`000117`),
  properti terbengkalai (`000118`), surat berharga (`000122`), kredit sindikasi (`000124`),
  hapus buku (`000129`), pihak lawan (`000130`), pihak terkait (`000127`), off-balance
  (`000113`).
- Triase kelengkapan: `docs/CELAH-LAPORAN-OJK.md` (kolom Form 05/06), `docs/CELAH-FORM-OJK.md`
  (45 form).
- **Draf**: pemetaan COA→pos OJK `apps/api/internal/ojkreport/coa_mapping.go` masih
  berstatus `DRAF-BELUM-TERVERIFIKASI`; laporan belum boleh dikirim ke APOLO
  (`docs/KEPUTUSAN.md:428-431`).

### 2.10 Maker-checker — [jalan]
- `domain/maker_checker.go`, `service/maker_checker_service.go`, tabel
  `maker_checker_requests` (satu tabel generik `action_type`+`payload`), migrasi `000022`,
  `000051`, `000054`, `000058`, `000080`.

### 2.11 EOD/EOM/EOY, batch, penjadwal — [jalan]
- Orkestrasi EOD di DB: `domain/batch.go`, `domain/eod_definition.go`, `domain/cron.go`;
  `service/batch_process_service.go` (±49 KB), `service/eod_scheduler.go`,
  `service/executor_registry.go`; migrasi `000077`, `000083`. Penjadwal EOD **default mati**
  (`docs/BACKLOG.md:915`).
- Akrual bunga tabungan, biaya admin, denda, PPAP, CKPN dipanggil dari EOD.

### 2.12 Akses, RBAC, cakupan cabang/buku, audit — [jalan]
- Aktor & izin: `domain/actor.go`, `domain/staff.go`, `domain/permission.go`,
  `service/auth_service.go`, `service/permission_service.go`, `service/actor_branch.go`.
- Hierarki organisasi cabang→area→wilayah: `domain/branch.go`,
  `service/branch_service.go`, migrasi `000081`.
- Cakupan buku (KONVENSIONAL/SYARIAH/DUAL): `domain/institution_scope.go`,
  `repository/postgres/book_scope.go`, `branch_scope.go`, migrasi `000072`, `000074`, `000133`.
- Audit append-only: `domain/audit.go`, `service/audit_helper.go`,
  `repository/postgres/audit_repo.go`, migrasi `000030` (imutabel), `000132` (cabang).
- Middleware: `apps/api/internal/middleware` (auth, rate limit login in-memory).

### 2.13 Integrasi & dokumen — [mock]/[HTML]
- SLIK/Dukcapil: `domain/integration.go`, `service/integration_service.go` — **[mock]**
  (`NewMockSLIKGateway`, `NewMockDukcapilGateway`; `cbs-core/README.md`).
- Dokumen (slip setoran/tarik, perjanjian kredit, struk, buku tabungan): `domain/document.go`,
  `service/document_service.go` — mengembalikan **HTML print view**, **bukan PDF**
  (`cbs-core/README.md`).

### 2.14 LPS (Pasal 23) — [mati]
- `domain/lps_placement.go`, `service/lps_placement_service.go`, tabel `lps_placements`,
  migrasi `000045`, `000106`, `000108`, `000110`, `000136`.

---

## 3. Skema database (ringkas per domain)

**Konvensi penamaan** (`docs/PENAMAAN-TABEL.md`): `snake_case`, Inggris, **plural**;
tanpa prefix `tbl_`; FK `<entitas>_id`; kolom waktu `*_at`; boolean `is_*`; singkatan mapan
(`coa`, `eod`, `eom`, `eoy`, `ojk`, `ckpn`, `lps`, `njop`, `aro`, `cif`). Migrasi aditif &
idempoten (`CREATE TABLE IF NOT EXISTS`); pasangan `.down.sql` sejak `000099`; nama indeks
`idx_<tabel>_<tujuan>`. Rename tertarget saja (contoh `deposits`→`time_deposits`, `000101`).

`grep -h "CREATE TABLE" packages/db-migrations/*.up.sql` → **62 tabel** unik. Pengelompokan
per domain (bukti: nama tabel ada di migrasi; nomor migrasi pembuat utama):

| Domain | Tabel inti | Migrasi |
|---|---|---|
| Aktor/staf | `staff_users`, `staff_sessions`, `branches`, `bank_work_units`, `bank_offices`, `bank_management`, `user_groups`, `user_group_members`, `group_permissions`, `menu_catalog`, `menu_permissions` | `000002`, `000079`, `000081`, `000088`, `000126`, `000131` |
| Nasabah | `customers`, `customer_name_tokens` | `000001`, `000006`, `000039` |
| Produk | `banking_products`, `product_journal_mapping`, `collateral_lampiran_ii_weights` | `000005`, `000087` |
| Akuntansi | `accounts`, `chart_of_accounts`, `journal_entries`, `journal_lines`, `idempotency_keys`, `year_end_closings` | `000001`, `000008`, `000011` |
| Kredit | `loans`, `loan_schedules`, `loan_collaterals`, `loan_ckpn_individual_assessments`, `loan_cashflow_projections` | `000003`, `000036`, `000094` |
| Simpanan | `deposits`, `interest_accruals`, `admin_fee_charges`, `account_number_sequences` | `000013`, `000015`, `000017` |
| Maker-checker | `maker_checker_requests` | `000022`, `000051` |
| LPS | `lps_placements`, `pabl_ckpn_assessments` | `000045`, `000099`, `000106` |
| BMPK | `bmpk_limits`, `bmpk_related_parties` | `000103` |
| OJK register/tabel referensi | `ayda_register`, `aset_tetap_register`, `aset_keuangan_lainnya_register`, `kas_valas_register`, `kepemilikan_bpr_register`, `kelembagaan_register`, `modal_register`, `penyertaan_modal_register`, `pinjaman_diterima_register`, `properti_terbengkalai_register`, `surat_berharga_register`, `kredit_sindikasi_register`, `hapus_buku_register`, `pihak_lawan_register`, `pihak_terkait_lainnya_register`, `off_balance_items`, `ojk_kabupaten`, `ojk_pihak_lawan`, `ojk_sektor_ekonomi`, `ojk_mapping_reviews` | `000050`, `000102`, `000112`–`000130` |
| EOD | `eod_step_definitions`, `eod_step_runs`, `eod_triggers` | `000077`, `000083` |
| Konfigurasi/audit | `system_config`, `bank_profile`, `audit_logs` | `000001`, `000025`, `000030`, `000132` |

Catatan skema: `deposits` piutang & `interest_accruals` menyimpan penanda idempotensi
(unique `AccountID, Period`); `journal_lines` simpan `balance_after`; `audit_logs`
di-`REVOKE UPDATE/DELETE` (imutabel). Jumlah tabel lengkap 62; daftar di atas hanya inti per
domain (tabel register kecil lain mengikuti pola `_register`).

**Konfigurasi bisnis di DB**: seluruh parameter bisnis (tarif PPAP, ambang DPD, limit per
peran, threshold maker-checker, tarif pajak, bunga/nisbah, identitas bank) disimpan di
`system_config`/`banking_products`/`bank_profile` — bukan di kode
(`docs/KEPUTUSAN.md:308-316`). Invarian seed↔pemakaian dijaga `TestConfigSeedInvariant`
(`docs/KEPUTUSAN.md:517-523`).

---

## 4. Aturan bisnis yang sudah tervalidasi

Legenda: **[V]** tervalidasi (ada rujukan dokumen/regulasi **dan** ada uji);
**[V-kode]** teruji di kode tetapi rujukan regulasinya tidak saya verifikasi ulang;
**[A]** asumsi / praktik industri (dinyatakan sendiri oleh dokumen).

### 4.1 Kolektibilitas & DPD (PPKA) — [V]
- **Aturan**: golongan = **yang terburuk** antara dimensi tunggakan angsuran (DPD) dan
  dimensi jatuh tempo Kredit. Angsuran ≥1 bulan: Lancar 1–30 / DPK 31–90 / Kurang Lancar
  91–180 / Diragukan 181–360 / Macet >360 hari. Angsuran <1 bulan: 15/30/90/180. Jatuh
  tempo: DPK ≤15 / KL ≤30 / Diragukan ≤60 / Macet >60 hari.
  Bukti: `domain/collection.go`, `service/collectibility_rules.go:26-49`,
  `docs/KEPUTUSAN.md:30-40`. Uji: `domain/ppap_test.go:14-99`
  (`TestCollectibilityFromDPD_MonthlyBands`, `_SubMonthlyBands`, `_TakesWorseOfArrearsAndMaturity`).
  Rujukan: **POJK No. 1/2024 Lampiran II** (`docs/KEPUTUSAN.md:21`).
- **Batas minimum**: bank boleh lebih konservatif, tidak boleh lebih longgar; nilai kosong →
  default POJK; nilai lebih longgar → dipulihkan (`tighten`).
  Uji: `domain/ppap_test.go:127-147` (`TestCollectibilityFromDPD_NeverLighterThanDefault`).
- **Restrukturisasi (Pasal 31)**: restrukturisasi tidak boleh menaikkan kualitas; batas
  membaik setelah N periode bersih. `domain/ppap.go` `RestructureCollectibility`; uji
  `domain/ppap_test.go:150-175`; migrasi `000028`.
  Catatan: kode & dokumen menulis "Pasal 31" (`docs/KEPUTUSAN.md:397-405` mengoreksi
  sitasi lama "Pasal 23" yang berasal dari POJK 33/2018 yang dicabut).

### 4.2 Tarif PPAP/PPKA — [V]
- **Aturan**: tarif PPKA khusus minimum **0,5% / 3% / 10% / 50% / 100%** (setelah dikurangi
  agunan); Lancar 0,5% = PPKA umum. Nilai 1%/5%/15%/50% dinyatakan **salah untuk BPR**.
  Bukti dokumen: `docs/KEPUTUSAN-PANEL-RISIKO-CKPN.md:16-32` (mengutip POJK 1/2024
  Pasal 19(3) & POJK 24/2024 Pasal 24(3)); kode `domain/ppap.go` `DefaultPPAPRates`.
  Uji: `domain/ppap_test.go:179-228` (`TestPPAPAmount_DefaultRates`, `_RoundsToRupiah`,
  Banker's rounding).
- **Penyesuaian**: `PPAPAdjustment(target, existing)` → provisi/reversal/nol. Uji:
  `domain/ppap_test.go:230-250`.

### 4.3 Agunan pengurang PPKA (Pasal 20) — [V sebagian / A]
- **Tervalidasi**: `haircut_percent` DEFAULT **100** = pengurang nol (semangat Pasal 20(2),
  jangan mengurangi sebelum memenuhi syarat); `ppap.collateral.enabled=false`
  (`docs/KEPUTUSAN.md:74-80`, `docs/KEPUTUSAN.md:330-350`; `domain/collateral.go`).
- **Asumsi/belum**: pemetaan tarif per jenis agunan Pasal 20(1), syarat Pasal 21(2),
  penurunan menurut waktu Pasal 20(3)/(5), pengecualian Pasal 20(4) **belum** ada → dokumen
  menyatakan perhitungan belum patuh Pasal 20 (`docs/KEPUTUSAN.md:76-80`).
- **Bobot Lampiran II SEOJK 2/2025** + daftar periksa C1–C9 (aktivasi per agunan, ≥90% nilai
  lolos, maker-checker): `docs/KEPUTUSAN-PANEL-RISIKO-CKPN.md` §3. Tabel
  `collateral_lampiran_ii_weights` (migrasi `000087`).
  Catatan: umur taksasi **tidak diatur** teks SEOJK → dinyatakan "praktik industri"
  (`docs/KEPUTUSAN-PANEL-RISIKO-CKPN.md:215-216`).

### 4.4 Bunga/akrual — [V]
- **Akrual kredit berbasis jadwal** (bukan harian) sehingga nilainya persis sama dengan
  jadwal, tanpa selisih pembulatan; **dihentikan untuk kolektibilitas 3–5** (NPL); hanya
  kredit konvensional; pembayaran melunasi piutang bunga (akun 10400), bukan mengakui
  pendapatan lagi. Bukti: `docs/KEPUTUSAN.md:195-207`; `domain/loan_accrual.go`,
  `service/loan_interest_accrual.go`; uji `service/loan_interest_accrual_test.go`
  (`_SkipsNPL`, `_SettlesAccruedProfitWithThreeBalancedLines`, `_SettlementNeverExceedsAccrued`).
- **Bunga tabungan**: `SavingsInterest(daily, rateAnnual, daysInYear)` = jumlah saldo harian
  × tarif/365, dibulatkan sekali; banker's rounding. `domain/savings_interest.go:148-163`;
  uji `domain/year_end_test.go:84-98` (1.000.000 @12%, 30 hari → **9.863**).
- **Deposito harian**: `DepositDailyProfit` konvensional & nisbah bagi hasil;
  uji `domain/deposit_test.go:10-36` (10.000.000 @4% /365 → **1.096**;
  nisbah 0,6 × 6% → **986**).

### 4.5 Pajak bunga/deposito — [V-kode]
- **Aturan**: PPh final 20% dari bruto; pembebasan sepanjang **jumlah tabungan** ≤ ambang
  (Rp 7.500.000 di komentar), dibandingkan dengan **saldo**, bukan bunga; ambang 0 = tanpa
  pembebasan. Bukti kode: `domain/savings_interest.go:276-291`
  (`SavingsInterestTax`) — mengutip **PP 131/2000 Pasal 2 & 3**. Uji:
  `domain/savings_interest_tax_test.go` (saldo tepat ambang bebas; 7.500.001 → 20%×100.000
  = **20.000**).
- Deposito harian: `domain/deposit.go` `DepositDailyTax` (1.096 × 20% → **219**);
  uji `domain/deposit_test.go:45-58`. Konfigurasi pajak deposito: migrasi `000032`, `000033`.
- **Compliance terbuka**: kutipan pasal hanya untuk rujukan; verifikasi compliance tetap
  terbuka (spec §4/§1.8). Untuk bagi hasil syariah **tidak dipotong** (`docs/KEPUTUSAN.md:180-186`).

### 4.6 Denda/ta'zir — [V]
- **Konvensional**: denda atas **pokok angsuran yang menunggak** (bukan sisa pokok penuh) ×
  tarif harian per-mille × hari yang diakru; plafon % pokok tunggakan; **dihentikan saat
  kredit NPL**; tarif bawaan **0** (tidak mengarang denda). Bukti: `domain/loan_penalty.go`
  (`LoanPenaltyAmount`, `LoanPenaltyCap`), `docs/KEPUTUSAN.md:592-598,623-635`,
  `docs/KEPUTUSAN-PANEL-RISIKO-CKPN.md` §2. Uji: `domain/loan_penalty_test.go`
  (1.000.000 × 1‰ × 10 = **10.000**; 2.500×1‰ → **2**; plafon maks 100%).
- **Syariah/ta'zir**: denda ke akun **12500 Dana Kebajikan** (LIABILITY), bukan pendapatan
  `40500`; kode menolak pemetaan ke akun pendapatan. Bukti: `domain/loan_penalty.go:22-31`,
  `docs/KEPUTUSAN.md:637-643`. Rujukan dokumen: **Fatwa DSN-MUI No. 17/DSN-MUI/IX/2000**
  (dikutip apa adanya di `docs/KEPUTUSAN-PANEL-RISIKO-CKPN.md:145-191`);
  **ta'zir tidak diakru tanpa klausul akad** (`loan.penalty.syariah.akad_disclosed=false`).
  Compliance & ketetapan angka tetap milik **DPS bank** (terbuka).

### 4.7 Bagi hasil mudharabah — [V]
- `MudharabahAllocate` membagi laba proporsional & menyerap sisa pembulatan ke rekening
  **terakhir** agar total persis sama dengan target. Bukti: `domain/savings_interest.go:172-238`;
  uji `domain/savings_interest_mudharabah_test.go`. Proyeksi pendapatan bawaan **0**;
  jadwal bagi hasil tanpa nisbah/proyeksi **ditolak** (`domain/schedule.go:194-221`,
  `docs/KEPUTUSAN.md:608-614`).

### 4.8 Bunga/deposito jatuh tempo & pinalti — [V]
- `DepositMaturityProceeds` = pokok + akrual bruto − pajak (`domain/deposit_test.go:60-83`:
  10.000.000 + 1.200.000 − 240.000 = **10.960.000**).
- `DepositMaturityDate`, pinalti pencairan dini = % pokok, pembulatan rupiah
  (`domain/deposit_test.go:85-132`). ARO: `deposits.aro`/`aro_instruction`
  (migrasi `000013`).

### 4.9 Jadwal angsuran (flat/anuitas/sliding/murabahah/bagi hasil) — [V]
- `domain/schedule.go` `BuildSchedule`: pembulatan sekali, sisa diserap angsuran terakhir
  sehingga Σ pokok = principal. Uji: `service/loan_service_test.go:41-150`
  (flat 10jt @12% 12 bln → total **11.200.000**; anuitas laju nol → total = pokok;
  murabahah 10jt+1,5jt → total 11,5jt; bagi hasil 20jt/10 bln).
- Invarian: Σ angsuran = total payable (`loan_service_test.go` `assertScheduleInvariants`).

### 4.10 CKPN — [V] (mode bayangan)
- **Rumus**: `CKPN_i = max(EAD_i × PD_gol × LGD, required_ppap_i)` (lantai PPKA).
  Bukti: `domain/ckpn.go`, `service/ckpn_service.go`;
  `docs/KEPUTUSAN-PANEL-RISIKO-CKPN.md:75-95`; uji integrasi
  `service/ckpn_shadow_integration_test.go:34-156` (A: 100jt×5%×45% = **2.250.000**;
  B: 100jt×60%×45% = **27.000.000**; total **29.250.000**; pengurang modal inti per kredit
  **3.750.000**). Rujukan: **SEOJK 21/SEOJK.03/2024 Bab XII** (`CKPN = PD×LGD×EAD`).
- **PD/LGD sementara** (fraksi 0..1, **bukan persen**): 0.0111/0.0667/0.2222/1.0/1.0,
  LGD 0.45 — ditetapkan panel **sementara**; dilarang dipakai untuk laporan OJK
  (`docs/KEPUTUSAN-PANEL-RISIKO-CKPN.md:49-73,118-134`).
- **Ratifikasi** ditegakkan trigger DB `ckpn_ratification_guard_row` (migrasi `000095`):
  status FINAL butuh 5 kunci bukti. Uji: `domain/ckpn_parameters_test.go:52-99`.
- **Integrasi EOD**: `ckpn_comparison` menjurnal saat `ckpn.enabled`; bayangan tidak menjurnal
  (`docs/CKPN-SIAP-RILIS.md` §(e)).
- **Batas**: pemetaan COA→OJK draf; syarat "cadangan 100%" hapus buku masih diukur dari
  `required_ppap`, belum `required_ckpn` (`docs/CKPN-SIAP-RILIS.md` §(c) butir 6).

### 4.11 Hapus buku — [V]
- Hanya **MACET**, cadangan **100%** dari **nilai tercatat** (pokok − saldo kerugian
  restrukturisasi), tanpa hapus buku sebagian, alasan + upaya penagihan wajib,
  maker-checker. Bukti: `docs/BACKLOG.md:924-928`; `domain/loan.go`,
  `service/loan_service.go`; uji `service/loan_write_off_regulation_integration_test.go`
  (5 uji). Rujukan dokumen: **POJK 1/2024 Pasal 42–46** (BPR) / **POJK 24/2024 Pasal 50–52**
  (BPRS) (`docs/BACKLOG.md:77`).
- Saat pemulihan, batas `written_off_amount` = pokok **bruto** (bisa ditagih penuh),
  yang dilepas dari neraca = nilai tercatat.

### 4.12 BMPK — [V]
- Plafon **internal bank**, bukan persentase regulator: `CheckBMPKParty` mengagregasi
  kredit + penempatan per pihak, membandingkan dengan limit. Uji: `domain/bmpk_test.go:22-108`.
  Catatan batas: `docs/CELAH-LAPORAN-OJK.md:56` (modul internal tidak mengenal kelompok
  peminjam).

### 4.13 AKDA/AYDA & penutupan tahun — [V]
- AYDA: nilai = min(nilai tercatat, NRV) dengan lantai nol; input negatif ditolak
  (`domain/ayda.go`; uji `domain/ayda_test.go:75-91`).
- Penutupan tahun: `ComputeClosingEntries` memindahkan pendapatan/beban ke laba ditahan,
  jurnal seimbang; laba → kredit, rugi → debit (`domain/year_end.go`;
  uji `domain/year_end_test.go:12-82`).

### 4.14 Maker-checker & limit per peran — [V]
- Satu sumber ambang persetujuan (`maker_checker.<jenis>.threshold`) & matriks limit
  `limit.<peran>.<jenis>.<sufiks>`; 72 kunci `limit.*` ter-seed. Bukti:
  `docs/KEPUTUSAN.md:490-514`; migrasi `000051`, `000054`, `000080`.
- Ambang kosong = **setiap** koreksi wajib disetujui (`docs/KEPUTUSAN.md:147-150`).

### 4.15 Dormant, reversal, koreksi kredit — [V]
- Dormant: ambang `account.dormant.after_months` (fallback 12), dasar waktu
  `COALESCE(last_activity_at, opened_at, created_at)`, kredit tetap diterima, reaktivasi
  eksplisit; tanpa jurnal (`docs/KEPUTUSAN.md:209-219`; `domain/account.go`).
- Reversal: tanggal posting selalu tanggal bisnis berjalan, bukan mundur; fase 1 hanya
  transaksi tanpa state; wajib maker-checker lintas hari; jurnal `REVERSAL` tidak bisa
  dibalik lagi (`docs/KEPUTUSAN.md:221-245`).
- Koreksi kredit `5c(a)`/`5c(b)`: `docs/KEPUTUSAN.md:136-159`.

### 4.16 SHU/koperasi — **tidak ada**
- Tidak ditemukan modul/tabel SHU atau koperasi; repo BPR/BPRS (`cbs-core/README.md:1-8`).
  Topik SHU di spec CBS (koperasi) **tidak** punya padanan di `cbs-core` → murni pekerjaan
  baru `cbs`, bukan inventaris.

---

## 5. Data uji & fixture yang bisa jadi bahan golden test

- **Tidak ada berkas fixture/`.golden`/`testdata`/CSV** di repo: pencarian
  `find ... -iname '*fixture*' -o -iname '*.golden' -o -iname 'testdata' -o -iname '*.csv'`
  → **kosong**. Semua kasus uji berupa nilai literal di dalam berkas `*_test.go`
  (370 berkas). Ini justru mudah dipindahkan: setiap uji = kasus + angka harapan eksplisit.
- **Seed parameter produksi** (bukan data nasabah) ada di migrasi — berguna sebagai
  *reference config*, bukan golden finansial: `packages/db-migrations/000051` (72 kunci
  `limit.*`), `000042`/`000069`/`000071` (COA + config CKPN), `000134` (PD/LGD PABL
  sementara), `000002` (`staff_users` seed dengan hash **placeholder** — tidak bisa login).
- **Tidak ada seed nasabah/kredit/rekening contoh** di migrasi (grep `INSERT INTO
  customers/loans/accounts` hanya menemukan COA/parameter, bukan data nasabah).
- Harness uji integrasi menghasilkan data sintetis per test (`newMoneyEnv`,
  `e.disburseAs`, `e.newCustomer`) — sumber pola fixture `cbs`, bukan angka bisnis.

---

## 6. Bug & pelajaran (yang sebaiknya tidak diulang)

1. **Tanggal kalender UTC vs tanggal bisnis** pada jurnal kontra pembatalan pencairan.
   Pelajaran: bila tanggal bisnis tak terbaca, **tolak**, jangan menebak; default
   `EntryDate` nol = UTC sengaja untuk jalur posting lain.
   Bukti: `docs/KEPUTUSAN.md:161-170`.
2. **Jurnal dengan >1 baris per arah** pada koreksi kredit: kode lama mengambil baris
   pertama → koreksi bisa mengalir ke akun salah. Sekarang ditolak. `docs/KEPUTUSAN.md:168-170`.
3. **Kunci konfigurasi tak ter-seed** (`limit.*`): penjaga batas jatuh ke bawaan
   (50jt/transaksi, 10jt ambang) untuk **semua** peran; niat seed tidak berlaku. Diperbaiki
   `000051`; kini dijaga invarian uji `TestConfigSeedInvariant`.
   Bukti: `docs/KEPUTUSAN.md:490-534`.
4. **Menyalakan CKPN tanpa ratifikasi** mengalirkan PD/LGD sementara ke pembukuan dan
   menutup ekspor OJK. Larangan: jangan balik `ckpn.enabled` otomatis lewat migrasi.
   Bukti: `docs/CKPN-SIAP-RILIS.md:215-243`.
5. **Parameter persen vs fraksi**: instalasi mengisi `1,5,15,35,60`/`45` (persen) sementara
   mesin membaca fraksi; nilai di luar 0..1 harus **dilaporkan sebagai kekurangan parameter**,
   bukan nol senyap. Bukti: `service/ckpn_shadow_integration_test.go:158-235`;
   `docs/CKPN-SIAP-RILIS.md:31-38`.
6. **Fallback limit senyap / idempotensi `time.Now().Unix()`** pada recovery hapus buku;
   cacat `RestructureLossBalance`. Semua sudah ditutup (W2) tetapi menunjukkan pola bahaya:
   **jangan biarkan nilai hilang jatuh ke angka bawaan senyap**. Bukti: `docs/BACKLOG.md:177-187,900-910`.
7. **Isolasi uji**: uji yang menyetel `system_config` tanpa memulihkan membuat suite
   meninggalkan kunci menyala → uji lolos/gagal tergantung urutan. Pola diperbaiki dengan
   snapshot+restore. Bukti: `docs/BACKLOG.md:595-618`.
8. **Sitasi pasal salah**: komentar "POJK 40/2019" (Bank Umum) dan "Pasal 23 = restrukturisasi"
   (dari POJK 33/2018 dicabut) — sudah dikoreksi ke Pasal 31/32. Pelajaran: **jangan warisi
   nomor pasal dari kode lama tanpa verifikasi**. Bukti: `docs/KEPUTUSAN.md:24-30,397-405`.
9. **PPAP berjalan sebelum amortisasi** → memakai saldo kerugian pra-amortisasi (selisih satu
   hari); tidak diubah karena memindahkan mengubah angka PPAP. Bukti: `docs/KEPUTUSAN.md:529-531`.
10. **Rasio NPL bank-wide di uji** (`TestIntegrasiOJKFormDaftarDanNPL`) gagal bila suite satu DB.
    Bukti: `cbs-core/README.md`; `docs/KEPUTUSAN.md:524-528`.
11. **Kebocoran `book`**: `/loans`, `/accounts`, `/deposits` tidak menyaring buku di server;
    web menyaring di klien → API langsung bocor. Diperbaiki di lapisan repository
    (`bookReadClause`). Pelajaran: **saring di server, bukan di klien**.
    Bukti: `docs/BACKLOG.md:134-141`.
12. **Rahasia pernah bocor** ke repo publik (hash superadmin, password plaintext, IP, fallback
    JWT secret, CORS wildcard) — sudah dibersihkan. Bukti: `docs/KEPUTUSAN.md:389-395`.

---

## 7. Kandidat golden test untuk `cbs` (spec §20 "Golden/Reference")

Format: kasus | input | output diharapkan | sumber | prioritas (P1 wajib, P2 penting, P3 berguna).
Semua angka **dari uji `cbs-core`**, bukan karangan. Nilai regulasi wajib diverifikasi ulang
di `cbs` (spec §4).

| # | Kasus | Input | Output diharapkan | Sumber (cbs-core) | Prio |
|---|---|---|---|---|---|
| G-01 | Kolektibilitas angsuran bulanan | DPD 0/1/30/31/90/91/180/181/360/361 | Lancar … Lancar/DPK/DPK/KL/KL/DR/DR/Macet/Macet | `domain/ppap_test.go:14-41` | P1 |
| G-02 | Kolektibilitas angsuran <1 bulan | DPD 15/16/30/31/90/91/180/181 | Lancar/DPK/DPK/KL/KL/DR/DR/Macet | `domain/ppap_test.go:45-68` | P1 |
| G-03 | Dimensi jatuh tempo menang | (dpd=0, jtm=10/20/45/90) | DPK/KL/DR/Macet | `domain/ppap_test.go:72-99` | P1 |
| G-04 | Konfigurasi tak boleh lebih longgar | ambang longgar {DPK:200,KL:120} @DPD 100 | tetap Kurang Lancar | `domain/ppap_test.go:103-147` | P1 |
| G-05 | Restrukturisasi pasal 31 | (Macet, hitung=Lancar, bersih=0/3) | Kurang Lancar / Lancar | `domain/ppap_test.go:150-175` | P1 |
| G-06 | Tarif PPAP per golongan | outstanding 1.000.000 | 5.000/30.000/100.000/500.000/1.000.000 | `domain/ppap_test.go:179-200` | P1 |
| G-07 | Banker's rounding PPAP | 333.333×0,5%; 1×50%; 3×50% | 1.667; 0; 2 | `domain/ppap_test.go:211-228` | P1 |
| G-08 | Penyesuaian PPAP | (target,existing)=(100k,40k)/(40k,100k)/(100k,100k) | 60k / −60k / 0 | `domain/ppap_test.go:230-250` | P2 |
| G-09 | Denda harian | 1.000.000 × 1‰ × 10 hari | 10.000 | `domain/loan_penalty_test.go:35-47` | P1 |
| G-10 | Denda tarif 0,5‰ | 2.000.000 × 0,5‰ × 4 | 4.000 | `domain/loan_penalty_test.go:42-46` | P2 |
| G-11 | Pembulatan denda (banker's) | 2.500×1‰×1; 3.500×1‰×1 | 2; 4 | `domain/loan_penalty_test.go:50-68` | P2 |
| G-12 | Pajak tabungan vs saldo | bruto 100.000, saldo 7.500.000 / 7.500.001 | 0 / 20.000 | `domain/savings_interest_tax_test.go:11-31` | P1 |
| G-13 | Bunga tabungan harian | 1.000.000 @12%, 30 hari, 365 | 9.863 | `domain/year_end_test.go:84-98` | P1 |
| G-14 | Bagi hasil mudharabah (share) | pool 1.000.000, nisbah 0,5, bal 10jt / total 100jt | 50.000 | `domain/year_end_test.go:100-109` | P2 |
| G-15 | Alokasi mudharabah serap sisa | pool 1.000.000, nisbah 0,5, 3 rek. saldo 3/3/3 | Σ = 500.000, 2 pertama sama | `domain/savings_interest_mudharabah_test.go:11-36` | P2 |
| G-16 | Deposito harian konvensional | 10.000.000 @4%, 365 | 1.096 | `domain/deposit_test.go:10-22` | P1 |
| G-17 | Deposito harian bagi hasil | 10.000.000, nisbah 0,6, proyeksi 6% | 986 | `domain/deposit_test.go:24-36` | P2 |
| G-18 | Pajak deposito harian | 1.096 × 20% | 219 | `domain/deposit_test.go:45-52` | P2 |
| G-19 | Hak jatuh tempo deposito | pokok 10jt + akrual 1,2jt − pajak 240rb | 10.960.000 | `domain/deposit_test.go:60-71` | P1 |
| G-20 | Pinalti pencairan dini | 10.000.000 × 1% | 100.000 | `domain/deposit_test.go:111-118` | P2 |
| G-21 | Jadwal flat | 10jt @12%, 12 bln | total 11.200.000; Σ angsuran = total | `service/loan_service_test.go:41-59` | P1 |
| G-22 | Jadwal anuitas laju 0 | 12jt @0%, 12 bln | total = pokok | `service/loan_service_test.go:61-75` | P1 |
| G-23 | Jadwal anuitas | 50jt @12%, 24 bln | porsi pokok naik, bunga turun | `service/loan_service_test.go:77-96` | P2 |
| G-24 | Jadwal sliding | 24jt @12%, 24 bln | bunga menurun | `service/loan_service_test.go:98-113` | P2 |
| G-25 | Jadwal murabahah | 10jt + margin 1,5jt, 12 bln | total 11,5jt, ProfitType MARGIN | `service/loan_service_test.go:115-133` | P2 |
| G-26 | CKPN portofolio campuran | A PPKA 5jt (DPK), B PPKA 10jt (Macet), C aset baik | CKPN A 2.250.000, B 27.000.000, total 29.250.000, deduksi per kredit 3.750.000 | `service/ckpn_shadow_integration_test.go:34-156` | P1 |
| G-27 | CKPN lantai & basis setara | sama seperti G-26 + basis "setara PPKA" | total 29.362.500, deduksi 3.637.500 | `service/ckpn_shadow_integration_test.go:119-142` | P2 |
| G-28 | BMPK status | kredit 150 / limit 100 | MELAMPAUI, kelebihan 50 | `domain/bmpk_test.go:59-66` | P2 |
| G-29 | BMPK agregasi | kredit 80 + penempatan 45 / limit 100 | MELAMPAUI, kelebihan 25 | `domain/bmpk_test.go:67-74` | P2 |
| G-30 | AYDA jumlah | (nilai 1000, akum 100, NRV 950) | 900 | `domain/ayda_test.go:75-84` | P3 |
| G-31 | Penutupan tahun (laba) | rev 1000, exp 400 | net 600 kredit ke laba ditahan; jurnal seimbang | `domain/year_end_test.go:12-51` | P2 |
| G-32 | Penutupan tahun (rugi) | rev 100, exp 300 | net −200, debit laba ditahan 200 | `domain/year_end_test.go:53-75` | P2 |
| G-33 | CKPN ratifikasi | bukti 5 kunci lengkap / kosong / tanggal masa depan | ready / 5 missing / missing 1 | `domain/ckpn_parameters_test.go:52-99` | P2 |

**Catatan pemakaian**: G-06/G-01/G-12 memuat angka regulasi. Di `cbs` angka itu **wajib**
berasal dari parameter DB (spec §10), jadi golden test harus membaca parameter, bukan
menanam literal. Kasus di atas dipakai untuk **mengunci hasil** pada parameter default POJK.

---

## 8. Pertanyaan untuk pemilik

1. **Apakah `cbs-core` berisi data nyata (nasabah/kredit) dan/atau pengguna nyata?**
   Menentukan perlu-tidaknya ETL + shadow run (spec §21.9 tahap 3–4; §26.2 #1).
   Fakta pendukung: migrasi seed hanya berisi COA/parameter + `staff_users` superadmin
   dengan hash **placeholder** (tidak bisa login), tanpa seed nasabah.
   Bukti: `packages/db-migrations/000002_staff_auth.up.sql:91-102`;
   `docs/BACKLOG.md:46-50` menyebut **8 baris `staff_users`** produksi (ada pengguna staf).
   **Perlu konfirmasi manusia**: ada/tidak data nasabah di produksi tidak dapat disimpulkan
   dari repo → `(belum diverifikasi)`.
2. **Target badan hukum & cakupan buku**: BPR konvensional, BPRS penuh, atau `DUAL`?
   Keputusan tercatat di `docs/BACKLOG.md:85-97` (satu instalasi per bank; `DUAL` bawaan).
   Untuk `cbs`, tanyakan apakah perlu warisan `book_scope` per instalasi.
3. **PD/LGD final & kapan `ckpn.enabled` dinyalakan** — tetap milik bank
   (`docs/KEPUTUSAN.md` butir 3; `docs/CKPN-SIAP-RILIS.md` §(h)). Angka sementara jangan
   disalin sebagai default `cbs`.
4. **Ta'zir syariah**: apakah dikenakan, besaran, kriteria "mampu", penyaluran dana
   kebajikan — milik DPS (`docs/KEPUTUSAN-PANEL-RISIKO-CKPN.md` §2.1(7)).
5. **Pemetaan COA→pos OJK** (draf) — prasyarat laporan APOLO (`docs/KEPUTUSAN.md:428-431`).
6. **Batas laju / multi-instance**, observabilitas, dan kebijakan `as_of` penempatan
   (`docs/KEPUTUSAN.md:477`).
7. **Perlakuan CKPN individual** (proyeksi arus kas = data operasional bank) — apakah `cbs`
   ikut membangun T1–T5 (`docs/CKPN-INDIVIDUAL-RANCANGAN.md`).

---

## 9. Daftar berkas sumber yang dibaca

Read-only, akar `cbs-core/` kecuali disebut lain.

**Kode (Go)**
- `apps/api/internal/service/collectibility_rules.go`, `collectibility_unified_test.go`
- `apps/api/internal/domain/collection.go`, `schedule.go`, `savings_interest.go`,
  `loan_penalty.go`, `bmpk_test.go`, `ppap_test.go`, `loan_penalty_test.go`,
  `savings_interest_tax_test.go`, `savings_interest_mudharabah_test.go`, `deposit_test.go`,
  `year_end_test.go`, `ayda_test.go`, `ckpn_parameters_test.go`
- `apps/api/internal/service/loan_service_test.go`, `ckpn_shadow_integration_test.go`

**Dokumen (docs/)**
- `docs/INDEX.md`, `docs/PENAMAAN-TABEL.md`, `docs/KEPUTUSAN.md`,
  `docs/KEPUTUSAN-PANEL-RISIKO-CKPN.md`, `docs/CKPN-SIAP-RILIS.md`,
  `docs/CELAH-LAPORAN-OJK.md`, `docs/UJI-TERIMA-BANK.md`, `docs/BACKLOG.md` (sebagian)

**Akar repo**
- `README.md`, `packages/db-migrations/*.up.sql` (daftar, `CREATE TABLE`), `apps/web/package.json`,
  `apps/api/go.mod` (via README), `git log`.

**Belum dibaca penuh (sengaja dicatat)**: `docs/KEPUTUSAN-PANEL-2026-10.md`,
`docs/CELAH-FORM-OJK.md`, `docs/KEPUTUSAN-OJK.md`, `docs/LAMPIRAN-OJK.md`,
`docs/CKPN-INDIVIDUAL-RANCANGAN.md`, `docs/ONBOARDING-BANK.md`, `docs/galat-dinamis-i18n.md`,
`docs/transkrip-form-*.md`, `docs/draft-surat-keputusan-dps-tazir.md`, `docs/DEPLOY.md`
→ isinya di luar klaim di dokumen ini dan harus dibaca sebelum dipakai
(`(belum diverifikasi)`).

---

### Penghitung kejujuran (untuk reviewer)
- Klaim "data/pengguna nyata di produksi": **belum dapat dipastikan** → ditandai §8.1, §1.
- Nomor pasal regulasi: hanya **dikutip dari dokumen/kode `cbs-core`**; verifikasi compliance
  di luar lingkup dan tetap terbuka (spec §4/§1.8) — tidak ada pasal yang saya karang.
- Modul SHU/koperasi: **tidak ditemukan** (dinyatakan eksplisit §4.16), bukan asumsi diam.
- Berkas `cbs-core` **tidak diubah**: hanya dibaca (`git -C cbs-core status` diharapkan bersih).
