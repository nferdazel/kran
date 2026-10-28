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
  meminta skip = gagal, dan chunk-nya tidak pernah ditandai sukses.
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
