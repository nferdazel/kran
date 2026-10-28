# Modul `ledger`

## Tujuan & Bounded Context

`ledger` memiliki **buku besar**: Chart of Accounts, periode akuntansi, jurnal double-entry,
posting rule, saldo, serta trial balance. Modul bisnis **tidak** menulis jurnal
langsung — mereka memancarkan accounting event dan `ledger` memetakannya lewat posting rule
(spec §8.1). Bounded context lain hanya berbicara lewat `api.nim` dan event (spec §6.3).

Yang **bukan** milik modul ini: perhitungan bunga/PPAP/produk (modul bisnis), laporan keuangan
(`reporting`), dan orkestrasi tutup hari/bulan (`daycloser`).

## Aggregate & Aturan Bisnis Utama

- `CoaAccount` (`domain/coa.nim`): `code` unik, nama, `accountType`, `normalSide`, `postable`,
  status. Sisi normal adalah **invarian akuntansi** yang diturunkan dari tipe:
  ASSET/EXPENSE = DEBIT, LIABILITY/EQUITY/REVENUE = CREDIT (dijaga CHECK DB).
  `postable = false` menandai akun header/induk yang tidak boleh dipakai posting (T-073).
- Format kode akun = **parameter** `ledger.coa.code_pattern` (regex, dicocokkan seluruh string);
  bukan konstanta di kode (spec §10.5).
- `Period` (`domain/period.nim`): rentang tanggal **inklusif**, status OPEN/CLOSED. Tumpang tindih
  ditolak `EXCLUDE USING gist (daterange(...) WITH &&)`, bukan pemeriksaan aplikasi.
  Penutupan mengisi `closed_at`/`closed_by`; **alasan wajib** dan masuk audit.
- **Penutupan satu arah** (T-129/DB-4, `0045`): trigger `ledger.period_guard` hanya mengizinkan
  `OPEN → CLOSED`; `CLOSED → OPEN`, perubahan `period_id`/`created_*`, dan perubahan rentang
  ditolak. Tidak ada reopen — koreksi setelah tutup = jurnal pembalik, bukan membuka periode lagi.
- **Tutup periode menolak sesi kas OPEN** di rentangnya (409 `open_sessions`, T-129/LED-1). Tanpa
  penjagaan itu sesi tersebut tidak akan pernah bisa ditutup: jurnal penutupnya bertanggal sesi dan
  akan ditolak periode yang sudah CLOSED, sementara index "satu sesi OPEN per teller" menghalangi
  sesi baru.
- Urutan penutupan (tidak menutup periode lebih awal saat sebelumnya masih terbuka) **belum**
  ditegakkan di sini — itu tugas `daycloser` (Fase 5). Lihat `docs/tasks/T-072.md`.

## Jurnal (T-073)

- `ledger.journal` + `ledger.journal_line`: double-entry. **Immutable** — trigger menolak
  `UPDATE`/`DELETE`/`TRUNCATE`; koreksi hanya lewat **jurnal pembalik** (`reversal_of`).
- Keseimbangan `SUM(debit) = SUM(credit)` (minimal 2 baris) ditegakkan **constraint trigger
  deferred** → diperiksa saat `COMMIT`. Karena itu header + baris **wajib satu transaksi**;
  menyisipkan baris dengan autocommit akan ditolak.
- Tanggal bisnis harus berada di periode **OPEN** (trigger). Belum ada periode = tidak bisa posting.
  Trigger memakai `FOR SHARE` pada baris periode: penutupan periode yang belum `COMMIT` **tidak
  bisa ditembus** jurnal — insert menunggu lock, lalu melihat status `CLOSED` (O-089/D-091).
- Akun GL harus `postable` dan `ACTIVE` (trigger).
- `idempotency_key` unik; endpoint pembalik memakai header `Idempotency-Key` dan **idempoten**
  (permintaan ulang → 200 dengan jurnal yang sama). Jurnal yang sudah dibalik tidak bisa dibalik
  lagi; jurnal pembalik tidak bisa dibalik.
- Tanpa partisi pada Fase 1 — **D-072**.
- Immutability punya dua lapis: trigger **dan** privilege. Sejak `platform/0042` role runtime
  (`kran_runtime`) kehilangan `UPDATE/DELETE/TRUNCATE` pada `ledger.journal`/`journal_line`
  (T-129/DB-1). Yang masih berlaku: role aplikasi adalah **pemilik** tabel, jadi `kran_app` (dipakai
  migrasi) tetap bisa mengubah jurnal; jaminan ini melindungi jalur runtime, bukan superuser.
- Pembalik memakai akun dari jurnal asal; bila akun sudah dinonaktifkan, pembalik ditolak
  (fail-closed) — kebijakan alternatif dicatat **O-079**.
- **Jurnal milik subledger tidak bisa dibalik** (D-135): bila `deposit.transaction`,
  `deposit.transfer`, `teller.teller_session`, atau `teller.vault_topup_request` menunjuk jurnal
  itu, pembalik ditolak `409 journal_owned_by_subledger` + `params.subledger`. Alasannya: pembalik
  hanya memutar GL, sedangkan saldo rekening/vault/sesi tidak ikut berubah. Koreksi lewat modul
  asal. Deteksi: `apps/api/src/journal_ownership.nim` (data, bukan daftar event).

## Posting rule & konsumen outbox (T-074)

- `ledger.posting_rule` / `posting_rule_line`: mapping event → template jurnal, **data** bukan kode.
  Kondisi = subset payload; rule paling spesifik menang, tie-break `priority`, ambigu = gagal
  terlihat. Template Fase 1: tepat satu DEBIT + satu CREDIT, nominal `payload.amount`.
- Konsumen ada di composition root (`apps/api/src/posting.nim`) karena modul tidak boleh menyentuh
  outbox/inbox platform. Event akuntansi **wajib** membawa header outbox `{"accounting": true}`;
  tanpa itu event diabaikan.
- Idempotensi: `platform.inbox` (`consumer = "ledger-postings"`) + `journal.idempotency_key =
  "outbox:<eventId>"`. Event akuntansi tanpa rule → `markFailed`, setelah batas percobaan `DEAD`
  dengan `last_error` — tidak ada jurnal kosong.
- Worker `role=worker` menjalankan loop konsumen; batas dari parameter
  `ledger.posting.batch_size`, `max_attempts`, `retry_backoff_seconds`, `poll_interval_ms`.
- Pengelolaan rule lewat migrasi sampai ada API/UI (**O-080**).
- Rule transaksi simpanan dari migrasi idempoten: `DepositWithdrawn` (T-088b, `0012` = D 201/K 101.2)
  dan `DepositTransferred` (T-088c, `0013` = D 201/K 201 untuk pemindahbukuan/PB). `DepositPosted`
  (D 101.2/K 201) dari `0005` dipakai ulang. **Batas PB:** kedua sisi akun `201` yang sama → jurnal
  net-nol di GL; perpindahan per rekening dicatat di modul `deposit` (`deposit.transfer`), belum ada
  GL per pemilik — lihat `docs/ACCEPTED-LIMITS.md` dan T-101/Fase 3.
- Migrasi `0033_ledger_cash_clearing.sql` (T-118) memisahkan kas konter: `101` menjadi induk
  non-postable, `101.2 KAS DI TELLER` menggantikan `101` pada **semua** `posting_rule_line` yang
  sebelumnya menunjuk `101` (5 baris lintas `0005`/`0012`/`0014`). Jurnal historis tetap `101`.

## Saldo turunan & trial balance (T-075)

- `GET /api/v1/ledger/trial-balance?periodId=` — agregat debit/kredit per akun untuk rentang
  periode, **dihitung dari `journal_line`**, bukan cache. Total debit = total kredit (invarian DB).
- `ledger.balance_snapshot` adalah **cache kumulatif** `(account_code, as_of)`: berisi semua jurnal
  dengan `business_date <= as_of`. Satu-satunya penulisnya `ledger.rebuild_balance_snapshot(as_of)`;
  posting jurnal **tidak** menyentuhnya (**D-074**). Trial balance adalah **pergerakan periode**
  (bukan saldo kumulatif), jadi angka snapshot dan TB hanya sama bila tidak ada periode sebelumnya.
- Izin baca laporan memakai `ledger.journal.read` (tingkat institusi).

## Laporan saldo GL (T-082, D-096)

- `GET /api/v1/ledger/balances?periodId=` — saldo per akun: `opening` (kumulatif sebelum
  `startsOn`), `period` (mutasi dalam rentang **inklusif**), `closing` (= opening + mutasi),
  debit/kredit **terpisah** (bukan saldo bersih). Angka dari **satu** query agregasi atas
  `journal_line` (sumber kebenaran); `closing` turunan di domain (`report.closingDebit/Credit`).
- Baris = akun yang bergerak di periode **atau** bersaldo awal ≠ 0; akun tanpa apa pun absen.
- `source`: `ledger` bila dihitung dari jurnal; `snapshot` **hanya** bila periode CLOSED **dan**
  cache `balance_snapshot` pada `endsOn` terekonsiliasi dengan jurnal (cocok per akun, D-096).
  Snapshot tidak pernah dipakai untuk periode OPEN. `computedAt` = ISO-8601 UTC.
- Izin `ledger.journal.read`; periode tidak ada → 404; `periodId` bukan uuid → 400.

## Public API (`api.nim`)

- `coa` — `AccountType`, `NormalSide`, `AccountStatus`, `CoaAccount`, `parseAccountType`,
  `parseAccountStatus`, `normalSideOf`, `compileCodePattern`, `validateCode`, `validateName`.
- `period` — `PeriodStatus`, `Period`, `parsePeriodStatus`, `parseIsoDate`, `validateRange`,
  `validateCloseReason`.
- `report` — `TrialBalance`, `TrialBalanceLine`, `totalDebit`, `totalCredit`, `isBalanced`.
- `posting` — `PostingRule`, `PostingRuleLine`, `jsonContains`, `selectRule`,
  `validateTemplate`, `buildLines`.
- `journal` — `Journal`, `JournalLine`, `totalDebit`, `totalCredit`, `isBalanced`,
  `validateJournalLines`, `validateIdempotencyKey`, `validateSourceEvent`, `reversalLinesOf`,
  `validateReversalReason`.

## Event dipublish / dikonsumsi (versi)

- Publish: `period.closed` v1, aggregate `period`, payload `{periodId, startsOn, endsOn}`.
- Publish: `journal.posted` v1, aggregate `journal`, payload
  `{journalId, businessDate, reversalOf, totalDebit}` (dipakai untuk rekonsiliasi/real-time).
- Konsumsi: accounting event dari outbox (header `{"accounting": true}`) lewat konsumen
  `ledger-postings`, dipetakan posting rule → jurnal (T-074).

## Parameter key (+ sensitivitas, regulatory_refs)

| Key | Tipe | Scope | Default seed | Sensitivitas |
|---|---|---|---|---|
| `ledger.coa.code_pattern` | string (regex) | GLOBAL, INSTITUTION | `^[0-9]{1,3}(\.[0-9]{1,3})*$` | NORMAL |
| `ledger.posting.batch_size` | integer | GLOBAL, INSTITUTION | 50 | NORMAL |
| `ledger.posting.max_attempts` | integer | GLOBAL, INSTITUTION | 10 | NORMAL |
| `ledger.posting.retry_backoff_seconds` | integer | GLOBAL, INSTITUTION | 30 | NORMAL |
| `ledger.posting.poll_interval_ms` | integer | GLOBAL, INSTITUTION | 500 | NORMAL |

## Tabel & schema (migrasi `0001`–`0011`)

- `ledger.coa_account` — kode unik, tipe, sisi normal (CHECK konsisten), `postable`, status.
  Tidak ber-cabang: GL milik institusi (spec §9).
- `ledger.period` — rentang inklusif, status, `closed_at`/`closed_by`, EXCLUDE tumpang tindih,
  trigger penutupan satu arah (`0045`).
- `ledger.journal` / `ledger.journal_line` — jurnal immutable + pembalik, trigger keseimbangan
  deferred, periode OPEN, akun postable/ACTIVE, dan baris hanya boleh masuk dalam **transaksi yang
  sama** dengan header (lihat bagian Jurnal di atas).
- `ledger.posting_rule` / `posting_rule_line` — mapping event → template jurnal (T-074).
- `ledger.balance_snapshot` — cache saldo per `(account_code, as_of)`; sumber kebenaran tetap jurnal
  (T-075).
- COA awal (`0002_ledger_coa_base.sql`) adalah **contoh struktur** untuk pilot, bertanda
  `NEEDS-COMPLIANCE-REVIEW` (REG-011 `V!`): jangan dijadikan dasar laporan final sebelum review
  compliance. Ditaruh di migrasi (bukan `packs/*/seed/`) karena seed pack hanya untuk `--dev`.
- `0033_ledger_cash_clearing.sql` menambah `101.1 KAS DI VAULT` / `101.2 KAS DI TELLER` /
  `101.9 SELISIH KAS` (ASSET, DEBIT, postable) dan menjadikan `101 KAS` non-postable (induk).
  Kode akun itu **usulan struktur pilot** dari memo T-118, tetap `NEEDS-COMPLIANCE-REVIEW`.

## Task day-close yang didaftarkan

Belum ada. Penutupan periode **tidak** memakai cron/batch sendiri (AGENTS §1.7); integrasi
`daycloser` menyusul di Fase 5.

## Permission

| Permission | Resource | platform_admin |
|---|---|---|
| `ledger.coa.read` | `coa` | ya |
| `ledger.coa.manage` | `coa` | ya |
| `ledger.period.read` | `period` | ya |
| `ledger.period.manage` | `period` | ya |
| `ledger.journal.read` | `journal` | ya |
| `ledger.journal.reverse` | `journal` | ya |

Katalog: `modules/platform/migrations/0015_platform_rbac_ledger.sql` (COA/periode) dan
`0016_platform_rbac_ledger_journal.sql` (jurnal).

Aksi COA/periode adalah **aksi institusi**: selain `requirePermission`, handler memanggil
`authorizedAtBranch(db, principal, "", permission)` di dalam transaksi, sehingga grant yang
dibatasi satu cabang ditolak **403 `branch_not_allowed`** (D-062).

## Namespace i18n

Belum ada teks UI modul ini; nanti memakai prefix `ledger.`.

## Requirement regulasi terkait (REG-xxx → test)

REG-011 (standar akuntansi, SAK EP/PSAK) bertanda `V!` — **belum diverifikasi**. COA awal dan
aturan pengakuan belum diklaim patuh; lihat `NEEDS-COMPLIANCE-REVIEW` di migrasi COA.

## Batas yang belum ditegakkan (disengaja, tercatat)

- Akun kontra (CKPN/akumulasi penyusutan) belum bisa dimodelkan — **O-075**, menunggu keputusan
  accounting/compliance (REG-011 `V!`).
- Daftar COA/periode dibatasi 200 baris; paginasi menyusul bila perlu.
- Penutupan periode bersamaan: `UPDATE` 0 baris → 409 tanpa audit/event kedua.

## Keputusan & trade-off (link ADR)

- D-070: COA & periode T-072 — format kode = parameter, sisi normal = invarian kode, periode
  inklusif + EXCLUDE, COA awal lewat migrasi idempoten (bukan seed pack dev-only).

## Menjalankan test

- `./task test tledger` — unit tipe akun, pola kode, rentang periode.
- `./task test itledger` — seed COA, kode unik, CHECK sisi normal, EXCLUDE tumpang tindih.
- `./task test itapi_ledger` — jalur HTTP penuh + kontrak + audit/event.

Catatan kasus vakum: periode CLOSED yang tidak punya jurnal sama sekali dan cache-nya belum
pernah dibangun akan menjawab `source=snapshot` dengan daftar kosong, karena tidak ada angka yang
bisa dibantah. Dampak finansial nol; bila `source` dipakai sebagai bukti audit, periksa juga
keberadaan baris `balance_snapshot` pada `ends_on`.

## Simpanan koperasi: akun ekuitas provisoris (T-111)

- `ledger/0014` menambah akun `301.1` (SIMPANAN POKOK ANGGOTA) dan `301.2` (SIMPANAN WAJIB
  ANGGOTA) plus rule `DepositPosted` berkondisi `{"savingsKind":"POKOK"}` / `"WAJIB"` ke akun itu.
  Rule generik `101.2/201` tetap fallback untuk NULL/SUKARELA/TABUNGAN.
- Nomor akun dan klasifikasi ekuitas vs liabilitas **belum final**:
  `NEEDS-COMPLIANCE-REVIEW` + O-100. Jangan memakai akun ini sebagai dasar laporan final sebelum
  accounting owner menetapkan COA.
- Rule berkondisi hanya terpilih bila pemanggil mengirim `savingsKind` di payload
  (`postJournalSync`); payload kosong akan diam-diam memakai rule generik.

## Kas teller vs vault: sub-akun clearing (T-118)

- `ledger/0033` menambah `101.1 KAS DI VAULT`, `101.2 KAS DI TELLER`, `101.9 SELISIH KAS`
  (ASSET/DEBIT/postable) dan memindahkan posting kas konter dari `101` ke `101.2`. `101 KAS` kini
  induk non-postable, jadi posting langsung ke `101` ditolak trigger `postable`.
- Alasan: satu akun `101` membuat kas di laci dan kas di vault tak terpisah di neraca
  (memo `docs/proposals/t-118-operator-governance.md` §5 opsi A). Kode akun ini **struktur pilot**,
  tetap `NEEDS-COMPLIANCE-REVIEW` (REG-011 `V!`).
- **Berjurnal sejak T-118 (D-132, menutup O-097):** `ledger/0034` menambah posting rule sesi &
  selisih kas — buka `TellerSessionOpened` (D 101.2/K 101.1), tutup `TellerSessionClosed`
  (D 101.1/K 101.2), selisih `TellerCashOverage`/`TellerCashShortage` (D/K `101.9`) — dan top-up
  vault dijurnal **eksplisit** di handler approval (D `101.1`/K akun sumber, event
  `TellerVaultTopUp`). Jurnal ditulis sinkron di transaksi yang sama dengan mutasi vault; gate EOD
  tetap menunggu `daycloser` (Fase 3).

## Dipakai day-close (T-137)

- `ledger.daily_snapshot` (EOD): menulis ulang `ledger.balance_snapshot` untuk tanggal buku dan
  membuktikan cache sama dengan jurnal (`snapshotMatches`) **dalam satu transaksi**; bila tidak
  cocok, rebuild di-rollback dan `accountDiff` (maks 20) masuk `daycloser.task.metrics` bersama
  `snapshotHash`.
- `ledger.period_close` (EOM, fase pasca-tutup): menutup periode yang **memuat tanggal buku dan
  berakhir di bulan yang sama** lewat `closePeriodSystem` (audit `ledger.period.close` + event
  `period.closed`, `closed_by`/`updated_by` NULL = proses sistem). Bergantung pada snapshot dan
  ketiga gate pasca-tutup; sesi kas OPEN di rentang periode (`DAY-326`) atau periode sebelumnya
  yang masih OPEN (`DAY-328`) menahan penutupan. Periode yang lebih panjang dari sebulan (tahunan)
  dilaporkan `NOT_DUE`; tidak ada periode sama sekali = `DAY-324`.
