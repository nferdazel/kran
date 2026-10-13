# Modul `platform`

Lintas-modul: audit trail, outbox/inbox, dan (menyusul) user/role/session, parameter,
kalender, workflow, notifikasi (spec §8, §9.2).

## Isi saat ini (T-004)

| Bagian | Berkas | Catatan |
|---|---|---|
| Domain audit | `domain/audit.nim` | tipe `AuditEntry`; hash **tidak** dihitung di sini |
| Domain peristiwa | `domain/event.nim` | `OutboxEvent`, `EventStatus` |
| Repo audit | `infrastructure/audit_repo.nim` | `appendAudit`, `verifyChain` |
| Repo outbox | `infrastructure/outbox_repo.nim` | `appendEvent`, `claimBatch`, `markDone/Failed`, `redrive` |
| Repo inbox | `infrastructure/inbox_repo.nim` | `claimInbox` (de-dup per konsumen) |
| Migrasi | `migrations/0001..0003` | schema, audit_log, outbox+inbox |

`api.nim` (permukaan publik modul) menyusul bersama T-005 (parameter) / T-006 (auth):
saat ini belum ada konsumen lintas-modul, jadi belum ada yang perlu diekspor.

## Tabel yang dimiliki

- `platform.schema_migration` — dibuat `tools/dbtools`, bukan migrasi modul.
- `platform.audit_log` — **append-only** + hash chain.
- `platform.outbox`, `platform.inbox` — transactional outbox + de-dup.

## Invarian yang tidak boleh dilanggar

1. **Audit tidak bisa diubah**: trigger `audit_log_no_change_trg` menolak UPDATE/DELETE,
   `audit_log_no_purge_trg` menolak TRUNCATE. Hash dihitung trigger `audit_log_chain_trg` —
   jangan pernah menulis `hash`/`prev_hash` dari aplikasi.
2. **Payload hash harus stabil**: `platform.audit_log_payload()` memakai UTC eksplisit dan
   teks tanggal ISO. Jangan menambahkan kolom baru ke payload tanpa menyesuaikan fungsi itu —
   `audit_verify()` akan melaporkan seluruh baris lama sebagai rusak.
3. **Outbox ditulis satu transaksi** dengan perubahan state; `dedup_key` wajib unik dan
   bermakna (`<event>:<aggregate>:<versi>`).
4. **Dispatcher memakai `claimBatch`** (`FOR UPDATE SKIP LOCKED`), bukan SELECT lalu UPDATE
   terpisah — kalau tidak, dua dispatcher bisa mengirim peristiwa yang sama.
5. **Tidak ada nilai bisnis di kode**: `backoffSeconds`, `maxAttempts`, retensi audit, ukuran
   batch datang dari parameter DB (spec §10.4).

## Batas yang diketahui (jujur)

- Rantai hash mendeteksi perusakan **tanpa** rekalkulasi. Penyerang dengan hak tulis penuh
  bisa menulis ulang seluruh ekor rantai; **anchor harian** (spec §18.2) belum ada —
  dicatat di `docs/OPEN_ITEMS.md`.
- Proteksi append-only bersandar pada trigger. Pemisahan privilege (role aplikasi tanpa
  UPDATE/DELETE) baru berlaku saat role produksi dibuat — juga di `docs/OPEN_ITEMS.md`.
- Lock `pg_advisory_xact_lock` pada rantai menyerialkan transaksi yang menulis audit. Aman
  untuk volume Fase 0; bila jadi leher botol, ganti dengan `seq` + retry (ADR kecil).

## Menjalankan

```
./task devdb up                # tunnel DB dev (lihat docs/runbooks/dev-db.md)
./task test itplatform         # test integrasi modul ini (butuh CBS_DATABASE_URL)
./task dbtools migrate         # menerapkan migrasi
```

Migrasi ditulis dengan pola **expand-only**; perubahan destruktif butuh header
`-- dbtools:destructive <alasan>` dan dianggap keputusan terpisah (spec §9.1(11)).

## Parameter (T-005)

| Bagian | Berkas |
|---|---|
| Domain | `domain/param.nim` — urutan resolusi, validasi schema (subset), konversi bertipe |
| Repo | `infrastructure/param_repo.nim` — kandidat pada `as_of`, submit/approve/reject, `missingActiveKeys`, `LISTEN/NOTIFY` |
| Migrasi | `0004_platform_parameter.sql` |

Invarian tambahan:

6. **Satu nilai berlaku per (key, scope, tanggal)** — EXCLUDE menjangkau `ACTIVE` **dan**
   `SUPERSEDED` (D-008). Nilai lama dipangkas (`effective_to`), bukan dihapus.
7. **Semua aktivasi butuh orang kedua** (`checker <> maker`, ditegakkan skema). Aktivasi menulis
   audit + event `ParamChanged` ke outbox + `NOTIFY platform_param_changed`.
8. **Tidak ada fallback**: key tanpa nilai berlaku → pemanggil melempar `ParamNotFound`
   (spec §10.6). Jangan menambahkan default di kode.

Jebakan yang sudah ditemukan (jangan diulang):

- `db_connector.getRow` mengembalikan kolom kosong untuk 0 baris → pakai `singleRow`/`getAllRows`.
- `db_postgres.exec` hanya menerima status COMMAND_OK → `SELECT` (mis. advisory lock, `pg_notify`)
  harus lewat `getValue`/`execScript`.
