# Modul `daycloser`

Kerangka orkestrasi penutupan hari/bulan/tahun (spec §11). **Satu-satunya** tempat pekerjaan
terjadwal institusi dijalankan: modul lain mendaftarkan task, tidak membuat batch/cron sendiri
(AGENTS.md §1.7).

## Tujuan & Bounded Context

Modul ini memiliki **urutan** penutupan: registry task, DAG dependensi, rencana chunk, state
machine run/task/chunk, retry, pause/cancel, resume, segel hash hasil run, siklus business date
(freeze → tutup → rollover), dan salinan registry untuk UI/audit.

Modul ini **bukan** pemilik aturan bisnis. Akrual, jatuh tempo, dormant, snapshot saldo, dan tutup
periode GL adalah task milik modul masing-masing (`ledger`, `deposit`, `lending`, …) yang
didaftarkan lewat `api.nim`. Nilai bisnis tetap di parameter DB.

## Aggregate & Aturan Bisnis Utama

Tidak ada aggregate bisnis. Invarian yang ditegakkan:

- **DAG deterministik.** Task hanya boleh bergantung pada task yang sudah terdaftar (urutan boot);
  `resolve` mengurutkan topologis dan menolak dependensi di luar level yang diminta.
- **Satu run aktif per (scope, tanggal).** Dijaga unique index parsial + advisory lock per scope.
  Catch-up beberapa hari dijalankan berurutan, hari demi hari.
- **State machine eksplisit.** `PLANNED → PRECHECK → RUNNING → POSTCHECK → COMPLETED`; `FAILED` dan
  `BLOCKED` bisa dilanjutkan (`daycloser-resume`), `COMPLETED`/`CANCELED` terminal.
- **Chunk adalah checkpoint.** Chunk `SUCCEEDED` tidak dijalankan ulang saat resume; chunk
  `FAILED` dicoba lagi. Rencana chunk dibekukan saat run dibuat.
- **Parameter dibekukan per run** (`param_snapshot`), sehingga mengubah `daycloser.*` di tengah
  run tidak mengubah perilaku run yang sedang berjalan.
- **Tanggal buku mengikuti run**, bukan perintah terpisah: `OPEN → CLOSING` setelah PRECHECK,
  `CLOSING → CLOSED` + rollover ke hari kerja berikutnya + event `BusinessDateOpened` saat seal
  (satu transaksi). Pembatalan run membuka kembali tanggal yang dibekukannya (`CLOSING → OPEN`)
  dalam **satu transaksi** dengan `CANCELED`; `CLOSED` tidak pernah dibuka (spec §11.7).
- **Tanggal yang run-nya `CANCELED` boleh ditutup lagi** (run baru), karena tidak ada jalan lain
  memajukan buku. Task penutupan wajib idempoten per business date.
- **Selama `CLOSING`, perubahan HTTP ditolak** `409 business_date_closing` kecuali rute
  autentikasi, atau bila `daycloser.txn_policy_during_close = ALLOW`.
- **Task kritis gagal = run FAILED.** Task non-kritis yang gagal dicatat, run tetap selesai
  (penutupan tidak boleh tertahan oleh pekerjaan opsional).
- **Skip hanya untuk task non-kritis dan hanya pada task satu-chunk** — task multi-chunk yang
  berhenti di tengah meninggalkan pekerjaan separuh yang tak bisa dijelaskan. Task kritis yang
  meminta skip = gagal, dan chunk-nya tidak pernah ditandai sukses. Alasan skip disimpan di
  `daycloser.task.reason` (migrasi `0062`) karena monitor membaca DB, bukan log.
- **Registry divalidasi terhadap snapshot run** sebelum eksekusi/resume: task yang ditambah,
  dihapus, atau berubah kind/critical ditolak sebelum state run disentuh.
- **Segel** (`summary_hash`) mencakup hash snapshot parameter, state/attempt task, dan
  state/attempt chunk. Snapshot parameter diverifikasi terhadap hash-nya setiap kali dibaca.
- **Pause/cancel dibaca di batas chunk**; resume membersihkan `PAUSE` tetapi mempertahankan
  `CANCEL` sehingga run yang dipause tetap bisa dibatalkan.

## Public API (`api.nim`)

- `DayCloseTask`, `TaskContext`, `Chunk`, `TaskResult`, `TaskOutcome`, `TaskError`
- `CloseLevel` (dari `kernel/dayclose`)
- helper `okOutcome(metrics)`, `skipOutcome(reason)`, `taskError(code, message, retryable)`

Registry, orkestrator, dan repositori **tidak** diekspor: hanya composition root (`apps/api`) yang
mendaftarkan task dan menjalankan run.

## Gate pra & pasca-tutup (T-136)

Gate adalah task `PRECHECK`/`POSTCHECK` kritis yang **hanya membaca**; kegagalannya membuat run
`BLOCKED` (bukan `FAILED`), dan angkanya tersimpan di `daycloser.task.metrics` walaupun gagal.

| Task | Fase | Aturan | Kode temuan |
|---|---|---|---|
| `teller.sessions_closed` | PRECHECK | tidak ada sesi `OPEN` s.d. tanggal tutup; tidak ada sesi `CLOSED` bervarians ≠ 0 | `DAY-301`, `DAY-302` |
| `teller.pending_approvals` | PRECHECK | tidak ada pengajuan top-up vault `PENDING` | `DAY-303` |
| `ledger.suspense_zero` | PRECHECK | akun `daycloser.precheck.suspense_accounts` bersaldo nol (akun tidak dikenal → gagal) | `DAY-304`, `DAY-311`, `DAY-312` |
| `ledger.trial_balance` | POSTCHECK | Σ debit = Σ kredit kumulatif | `DAY-305` |
| `ledger.subledger_vs_gl` | POSTCHECK | total saldo rekening = saldo akun `daycloser.postcheck.subledger_gl_accounts` | `DAY-306/307/308` |
| `ledger.no_late_postings` | POSTCHECK | tidak ada jurnal bertanggal tutup yang direkam setelah pembekuan (TOCTOU gerbang HTTP); tanggal tidak `CLOSING` → gagal | `DAY-309`, `DAY-310` |

Karena PRECHECK berjalan sebelum freeze, kegagalan gate pra-tutup **tidak** membekukan tanggal buku;
yang menahan adalah run `BLOCKED` itu sendiri. Kegagalan gate pasca-tutup meninggalkan tanggal
`CLOSING` sampai run di-resume atau dibatalkan (D-150).

`resume` mengulang **semua** gate (task dan chunk `SUCCEEDED` dikembalikan ke `PENDING`), karena
keadaan yang disertifikasi gate pra-tutup bisa berubah selama run berhenti — sertifikat lama tidak
boleh dipakai untuk menyegel.

## Event dipublish / dikonsumsi (versi)

| Event | v | Kapan | Payload |
|---|---|---|---|
| `BusinessDateOpened` | 1 | saat seal, satu transaksi dengan `run → COMPLETED` dan rollover | `businessDate` (tanggal baru), `closedDate`, `scopeType`, `scopeId`, `runId` |

Progress realtime (`DayCloseProgress`) menyusul bersama UI monitor (T-139).

## Parameter key (+ sensitivitas, regulatory_refs)

| Key | Arti |
|---|---|
| `daycloser.chunk_size` | jumlah entitas per chunk (default 1000) |
| `daycloser.max_attempts` | percobaan maksimum per chunk/task |
| `daycloser.retry_backoff_seconds` | jeda tetap antar percobaan |
| `daycloser.txn_policy_during_close` | `REJECT` (default) menolak semua perubahan HTTP saat `CLOSING`; `ALLOW` membiarkannya (risiko race ditanggung institusi) |
| `daycloser.precheck.suspense_accounts` | akun yang wajib bersaldo nol sebelum tutup (awal `101.9` selisih kas) |
| `daycloser.postcheck.subledger_gl_accounts` | akun GL kewajiban pembanding total subledger simpanan (awal `201`, `202`) |

`chunk_size`, `max_attempts`, dan `retry_backoff_seconds` kelas `teknis`; sensivitas `NORMAL`;
tanpa referensi regulasi. `txn_policy_during_close` kelas **kebijakan** dengan
`compliance: NEEDS-COMPLIANCE-REVIEW` (pilihan `ALLOW` adalah keputusan operasional institusi, bukan
anjuran). Paralelisme & timeout task belum diparameterkan karena belum ditegakkan (lihat
`docs/ACCEPTED-LIMITS.md`).

## Tabel & schema

Schema `daycloser` (migrasi `0051_daycloser_schema.sql`):

- `run` — satu eksekusi per (scope, business date); `param_snapshot`, `summary_hash`.
- `task` — state/attempt/error/metrics per task.
- `chunk` — checkpoint per potongan; FK ke `task`.
- `task_registry` — salinan registry saat boot untuk UI/audit.
- `checkpoint` — `last_business_date` per entitas untuk task `PER_ENTITY` (hanya boleh maju).

## Task day-close yang didaftarkan

| Task | Level | Kritis | Catatan |
|---|---|---|---|
| `platform.idempotency_sweep` | EOD | tidak | Hapus klaim idempotensi kedaluwarsa bertahap (`chunk_size` per putaran); menutup T-089/O-094 sebagian |

## Permission

Belum ada izin HTTP; perintah dijalankan lewat `ctl` (operator). Izin `daycloser.run.execute` dan
UI-nya menyusul di T-139.

## Namespace i18n

Belum ada teks UI. Prefix `dayclose.` disiapkan untuk T-139.

## Requirement regulasi terkait (REG-xxx → test)

Tidak ada. Kerangka ini teknis; kewajiban retensi/audit penutupan mengikuti modul pemilik task.

## Keputusan & trade-off (link ADR)

- D-148: snapshot parameter inline (bukan FK), `scope_id` teks, kolom `control`, eksekusi chunk
  sekuensial, kode keluar `ctl daycloser-status` sebagai kontrak gate deploy.
- D-149: siklus business date dimiliki run; seal + rollover satu transaksi; `CLOSING → OPEN` hanya
  sebagai abort; gerbang HTTP terpusat; bootstrap tanggal buku eksplisit.
