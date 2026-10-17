# Modul `platform`

Lintas-modul: audit trail, outbox/inbox, parameter, kalender & business date, dan (menyusul)
user/role/session, workflow, notifikasi (spec §8, §9.2).

## Isi saat ini (T-004)

| Bagian | Berkas | Catatan |
|---|---|---|
| Domain audit | `domain/audit.nim` | tipe `AuditEntry`; hash **tidak** dihitung di sini |
| Domain peristiwa | `domain/event.nim` | `OutboxEvent`, `EventStatus` |
| Repo audit | `infrastructure/audit_repo.nim` | `appendAudit`, `verifyChain` |
| Repo outbox | `infrastructure/outbox_repo.nim` | `appendEvent`, `claimBatch`, `markDone/Failed`, `redrive` |
| Repo inbox | `infrastructure/inbox_repo.nim` | `claimInbox` (de-dup per konsumen) |
| Migrasi | `migrations/0001..0007` | schema, audit_log, outbox+inbox, parameter, kalender, auth, NOTIFY outbox (realtime) |

`api.nim` (permukaan publik modul) menyusul bersama T-005 (parameter) / T-006 (auth):
saat ini belum ada konsumen lintas-modul, jadi belum ada yang perlu diekspor.

## Tabel yang dimiliki

- `platform.schema_migration` — dibuat `tools/dbtools`, bukan migrasi modul.
- `platform.audit_log` — **append-only** + hash chain.
- `platform.outbox`, `platform.inbox` — transactional outbox + de-dup.
- `platform.param_definition`, `platform.param_value` — parameter framework (T-005).
- `platform.holiday`, `platform.business_date` — kalender & tanggal buku (T-007).
- `platform.app_user`, `platform.role`, `platform.permission`, `platform.role_permission`,
  `platform.user_role`, `platform.role_conflict`, `platform.session` — identitas, akses, sesi (T-006).

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

## Invarian: urutan commit == urutan `seq` outbox

`platform.outbox.seq` dialokasikan saat **INSERT**, sedangkan commit bisa terjadi dengan urutan
berbeda. Pump realtime membaca tabel dengan kursor `seq` (`eventsAfter`), jadi bila urutan itu
terbalik, peristiwa yang commit belakangan akan **terlewat** — bukan sekadar tertunda.

Aturan penulis: **transaksi yang menulis peristiwa outbox wajib menulis entri audit lebih dulu, di
transaksi yang sama.** Trigger rantai audit memegang `pg_advisory_xact_lock(hashtext(
'platform.audit_log'))` **sampai commit**, sehingga penulis audit terserialkan dan urutan commit
mengikuti urutan `seq`.

Ini bukan konvensi gaya. Dua test di `tests/itoutboxcursor.nim` menjaga keduanya: (1) penulis kedua
benar-benar menunggu commit penulis pertama dan `seq`-nya lebih besar — **GAGAL** bila lock audit
dilepas; (2) bila aturan itu dilanggar (event tanpa audit lebih dulu), kursor `seq` memang melewatkan
peristiwa yang commit belakangan.

## Menjalankan

```
./task devdb up                # tunnel DB dev (lihat docs/runbooks/dev-db.md)
./task test itplatform         # test integrasi modul ini (butuh KRAN_DATABASE_URL)
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
   (spec §10.6). Jangan menambahkan default di kode. Startup check (`missingActiveKeys`, O-057)
   memakai jalur `resolveCandidate` + `lookupFor` yang **sama** dengan pembacaan runtime, jadi
   "aktif" di sini berarti "terlihat resolusi" — `GLOBAL` selalu terlihat, tetapi `scopeId` kosong
   bukan wildcard (kandidat ber-id konkret tidak menggantikan).
9. **Lookup scope bertipe eksplisit** (D-041): `ScopeValueLookup` mengembalikan `Option[string]` —
   `some(id)` berarti tipe itu diminta, dan `some("")` **sah** (institusi akar, `scope_id` NULL);
   `none` berarti tidak diminta. Id kosong bukan wildcard, dan tidak ada fallback antar level.
10. **Visibilitas daftar mengikuti wewenang baca, dan disaring di query** (D-046 butir 6, D-047/D-055):
   aturan "grant mana menutupi scope mana" hidup satu kali di `domain/authz` (`readableScopeFilter`;
   `mayReadScope` diturunkan dari padanya). `paramValueRows`/`listAudit` hanya menerjemahkannya ke SQL,
   **bukan** menyaring setelah `LIMIT` — kalau disaring belakangan, baris yang tidak boleh dibaca
   memakan jatah halaman. `GLOBAL` selalu terlihat; `INSTITUTION` hanya untuk grant tanpa batas cabang;
   `BRANCH` per cabang yang ditutup grant; `PRODUCT`/`SEGMENT`/`ROLE` gagal-tertutup (belum ada model
   keanggotaan). Pengajuan nilai memakai predikat yang sama (pengaju tidak boleh mengusulkan lebih dari
   yang ia boleh baca) → `403 scope_not_readable`. Pembacaan cabang di luar cabang tugas menulis
   `param.read_cross_branch` — satu entri per cabang — dan bila pencatatan itu gagal, permintaannya
   ikut gagal (jangan menyajikan tanpa jejak).

Jebakan yang sudah ditemukan (jangan diulang):

- `db_connector.getRow` mengembalikan kolom kosong untuk 0 baris → pakai `singleRow`/`getAllRows`.
- `db_postgres.exec` hanya menerima status COMMAND_OK → `SELECT` (mis. advisory lock, `pg_notify`)
  harus lewat `getValue`/`execScript`.

## Kalender & business date (T-007)

| Bagian | Berkas |
|---|---|
| Domain | `domain/calendar.nim` — `CalendarShape`, hari kerja, `nextWorkingDay`, `closeLevelsFor`, state + `canTransition` |
| Repo | `infrastructure/calendar_repo.nim` — bentuk kalender dari param, `platform.holiday`, lifecycle business date (`ensure`/`transition`/`rollover`), `workingDayInfo` |
| Migrasi | `0005_platform_calendar.sql` |
| Parameter | `platform.calendar.weekend_days` (json, nomor hari ISO 1=Senin…7=Minggu), `platform.calendar.fiscal_year_start_month` |

Invarian tambahan:

9. **Nilai kalender tidak di kode**: akhir pekan & awal tahun fiskal dari parameter, hari libur
   dari `platform.holiday`. Tidak ada fallback bila param kosong (error).
10. **Jalur state business date hanya satu**: `OPEN → CLOSING → CLOSED`, lalu rollover mengubah
    `current_business_date` pada baris `CLOSED` (state kembali `OPEN`). Reopen/reverse EOD
    dilarang sampai ada kebijakan approval (§11.7). Transisi dijaga `canTransition` + CAS
    (`UPDATE ... WHERE state = expected`).
11. **`current_business_date`, bukan `current_date`** — D-011; keunikan scope lewat
    `UNIQUE INDEX (scope_type, COALESCE(scope_id,''))`, karena Postgres menolak ekspresi di PK.

Catatan penempatan: `CloseLevel` masih di `domain/calendar.nim`. Saat modul `daycloser` lahir
(Fase 3), tipe itu pindah ke sana dan modul ini hanya menyediakan `closeLevelsFor`.

## Identitas, akses & sesi (T-006)

| Bagian | Berkas |
|---|---|
| Domain otorisasi | `domain/authz.nim` — kode izin `modul.resource.action`, branch scoping, `authorize` (SoD fail-closed), kebijakan sesi & password |
| Domain scope | `domain/scope.nim` — `ScopeRef` + konvensi lookup parameter (dipakai kalender & auth) |
| Hash password | `infrastructure/password_hasher.nim` — PBKDF2-HMAC-SHA256; hash token sesi (SHA-256) |
| Repo | `infrastructure/auth_repo.nim` — user/lockout, role/permission/SoD, sesi |
| Alur | `infrastructure/auth_service.nim` — `authenticate`, `sessionFor`, `touch`, `logout`, `logoutAll`, `authorizeUser`, `changePassword`, `bootstrapFirstAdmin` |
| Migrasi | `0006_platform_auth.sql` (tabel) + `0008_platform_rbac_catalogue.sql` (katalog izin & role sistem) |

Invarian tambahan:

12. **Password tidak pernah disimpan/di-log mentah**: DB hanya menyimpan
    `algo$iterasi$salt$digest`; parameter KDF ikut tersimpan supaya hash lama tetap valid.
13. **Kebijakan dari parameter** (spec §10.4): panjang minimum password, iterasi PBKDF2, batas
    gagal login, masa lockout, umur sesi idle/absolut. Tidak ada default di kode.
14. **Token sesi hanya ada di memori/klien**: DB menyimpan hash-nya (`session.token_hash`).
15. **SoD fail-closed**: penugasan role berkonflik ditolak `grantRole`; bila konflik tetap ada di
    data, `authorize` menolak semua aksi.
16. **Anti-enumerasi**: user tak dikenal & password salah sama-sama `INVALID_CREDENTIALS`;
    user tak dikenal dicatat di audit sebagai digest, bukan nama mentah (§18.2 logging tanpa PII).
    **Kata sandi selalu diverifikasi lebih dulu** (O-034): `locked`/`inactive` baru diberitahukan
    setelah kata sandi benar, dan akun tak dikenal mengerjakan PBKDF2 tiruan berbiaya setara
    (`dummyPasswordHash`) supaya waktu respons tidak membedakan. Biaya tiruan mengikuti parameter
    iterasi saat ini; akun lama yang hash-nya dibuat dengan iterasi berbeda tidak ikut setara —
    yang dijaga adalah kesetaraan dengan "akun yang wajar".
17. **Admin pertama sekali-jalan** (T-027): `bootstrapFirstAdmin` menolak bila username sudah ada
    atau sudah ada pengguna yang memegang role admin — jadi perintah `ctl bootstrap-admin` tidak
    bisa diam-diam jadi jalur membuat admin kedua. Kata sandi awalnya diacak CSPRNG, dicetak sekali
    ke stdout, hanya hash-nya tersimpan, dan pengguna dibuat `must_change_password = true`.
18. **Sesi wajib-ganti hanya boleh mengganti kata sandi**: `requirePermission` (satu tempat, di
    `apps/api/src/access.nim`) menolak rute ber-izin dengan 403 `password_change_required` selama
    `must_change_password` masih true; `getSession`, `logout`, dan `changePassword` tidak melewatinya
    sehingga alurnya tetap bisa diselesaikan. Jalur realtime memakai definisi yang sama
    (`sessionCanWork`).
19. **Katalog izin & role sistem tinggal di migrasi**, bukan di seed dev: `dbtools seed` hanya
    menerapkan `packs/*/seed/*.sql` dengan `--dev`, sehingga katalog di sana berarti admin pertama di
    produksi dibuat tanpa satu pun izin (`0008_platform_rbac_catalogue.sql`).

Catatan: alur auth tinggal di `infrastructure` (butuh DB). Saat port/use case lapisan
`application` lahir (pola T-016), isi `auth_service.nim` pindah ke `application/`.

## Realtime (T-009, spec §19.1/§19.2)

| Bagian | Berkas | Catatan |
|---|---|---|
| Hub (murni) | `application/realtime.nim` | topik, langganan, fanout, amplop pesan (`encodeEvent`/`encodeSubscribed`/`encodeResync`/`encodeError`), pembacaan pesan kontrol klien, batas protokol sebagai parameter (`SubscriptionLimits`) |
| Pendengar outbox | `infrastructure/outbox_listener.nim` | `LISTEN kran_outbox`, tunggu notifikasi, baca peristiwa setelah token (`outbox_repo.fetchAfter`/`latestEventId`) |
| Transport | `apps/api/src/events.nim` | handshake WS, state koneksi, `TopicPolicy`, replay/resume, pump (`LISTEN` → hub → soket) |
| Trigger NOTIFY | `migrations/0007_platform_outbox_notify.sql` | `pg_notify('kran_outbox', outbox_id)` pada `AFTER INSERT` di `platform.outbox` |
| Skema amplop | `packages/contracts/events/realtime-envelope.v1.schema.json` | spec §12.4: skema event tidak ditaruh di kontrak OpenAPI |

Invarian tambahan:

9. **NOTIFY bukan pengangkut data**: payload hanya `outbox_id`; isi peristiwa dibaca dari tabel.
   Kanal dipakai bersama `outbox_listener.nim` (nama konstanta di sana) — jangan mengarang kanal
   baru di modul lain.
10. **Urutan peristiwa memakai `seq`** (`bigint identity`), bukan `occurred_at`; resume token yang
    tidak dikenal diperlakukan sebagai "mulai dari awal", dan klien de-dup berdasarkan `id`.
11. **Kebijakan realtime default menolak** (`denyPolicy`): sampai sesi nyata (T-012) terpasang,
    stream tertutup untuk semua identitas. Uji menyuntikkan kebijakannya sendiri
    (`allowAllPolicy` di transport, uji topik per-izin untuk yang lain).
12. **Pump menyambung ulang, dan titik mulai hanya ditetapkan pada sambungan pertama** (T-029):
    putusnya koneksi DB pump tidak mematikan realtime diam-diam — pump menyambung ulang dengan
    backoff, dan lamanya keadaan itu terbaca lewat `pumpDegradedSeconds`. `lastEventId` **tidak**
    di-reset ke "peristiwa terbaru" saat menyambung ulang: itu akan melewati peristiwa yang terjadi
    selama putus, padahal pembacaannya memang dari tabel lewat token yang sama. Keadaan itu juga
    terlihat dari luar: `readiness.realtimeProbe` baru menyatakan `failed` setelah
    `pumpReadyGraceSeconds` (30 detik), supaya sambungan ulang singkat tidak membuat penyeimbang beban
    membuang proses yang sebenarnya sehat. Sejak T-041 lag-nya juga terbaca: `readiness.pumpLagProbe`
    memakai `outbox_repo.oldestUndeliveredSeconds` (usia peristiwa tertua dengan `seq` setelah kursor
    pump, dibaca lewat `pumpCursor`) dan `failed` di atas `pumpLagSeconds` (30 detik). Saat proses
    berhenti, pump dihentikan **setelah** permintaan HTTP yang sedang berjalan selesai (drain, T-032).
13. **Izin diperiksa ulang per klien, bukan sekali saat handshake** (T-030): `sweepSessions` memeriksa
    tiap klien **paling sering** sekali per `sessionRecheckSeconds` (bukan setiap peristiwa) dan
    menutup langganan yang sesi/izinnya sudah tidak sah. Konsekuensi yang diterima: ada jendela
    staleness maksimum satu interval — peristiwa masih bisa terkirim antara izin dicabut dan
    pemeriksaan berikutnya (`0` berarti setiap putaran pump). Satu koneksi pump menempati satu koneksi
    pool, jadi jumlahnya ikut menentukan kebutuhan pool.
14. **Transport bersandar pada dua sifat Mummy yang tidak dijanjikan API publiknya** (T-034, D-037):
    `send` aman dari thread lain (pump) sambil handler memakai soket yang sama — penjaminnya adalah
    antrean kirim per koneksi; dan `close` aman dari thread lain serta tidak menutup soket klien lain
    setelah `forget`. Bila versi minor mengubahnya **tidak ada** kegagalan kompilasi, hanya pesan yang
    hilang atau soket yang menggantung saat beban — karena itu `kran.nimble` membatasi
    `mummy >= 0.4.8 & < 0.5.0` dan ada daftar periksa upgrade di D-037. Antrean kirim keluar masih
    tidak dibatasi (O-028).
