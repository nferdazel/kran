# Modul `platform`

Lintas-modul: audit trail, outbox/inbox, parameter, kalender & business date, user/role/session, dan
(menyusul) workflow, notifikasi (spec §8, §9.2).

## Isi saat ini (T-004)

| Bagian | Berkas | Catatan |
|---|---|---|
| Domain audit | `domain/audit.nim` | tipe `AuditEntry`; hash **tidak** dihitung di sini |
| Domain peristiwa | `domain/event.nim` | `OutboxEvent`, `EventStatus` |
| Repo audit | `infrastructure/audit_repo.nim` | `appendAudit`, `verifyChain` |
| Repo outbox | `infrastructure/outbox_repo.nim` | `appendEvent`, `claimBatch`, `markDone/Failed`, `redrive` |
| Repo denyut worker | `infrastructure/worker_repo.nim` | `touchWorkerHeartbeat`, `workerHeartbeatAgeSeconds`, `deadEventCount` (O-081) |
| Repo inbox | `infrastructure/inbox_repo.nim` | `claimInbox` (de-dup per konsumen) |
| Repo idempotency | `infrastructure/idempotency_repo.nim` | `claimIdempotency`, `completeIdempotency` (T-084) |
| Migrasi | `migrations/0001..0037` | schema, audit_log, outbox+inbox, parameter, kalender, auth, RBAC, NOTIFY outbox (realtime), heartbeat, SoD, idempotency |

`api.nim` (permukaan publik modul) belum dibuat: saat ini belum ada konsumen lintas-modul, jadi
belum ada yang perlu diekspor.

## Tabel yang dimiliki

- `platform.schema_migration` — dibuat `tools/dbtools`, bukan migrasi modul.
- `platform.audit_log` — **append-only** + hash chain.
- `platform.outbox`, `platform.inbox` — transactional outbox + de-dup.
- `platform.worker_heartbeat` — denyut worker untuk `/readyz` (teknis, O-081).
- `platform.param_definition`, `platform.param_value` — parameter framework (T-005).
- `platform.holiday`, `platform.business_date` — kalender & tanggal buku (T-007).
- `platform.app_user`, `platform.role`, `platform.permission`, `platform.role_permission`,
  `platform.user_role`, `platform.role_conflict`, `platform.session` — identitas, akses, sesi (T-006).
- `platform.user_mfa` — faktor kedua per akun (TOTP); rahasia **terenkripsi** (T-046).
- `platform.branch` — master cabang: kode **3 digit** + nama (D-130). Kode dipakai sebagai prefiks
  nomor rekening; modul lain tetap menyimpan `branch_id` tanpa FK.
- `platform.idempotency_key` — klaim `Idempotency-Key` per principal (T-084, D-098). Baris hanya
  ditulis di dalam transaksi bisnis; respons non-2xx tidak pernah disimpan; TTL dari parameter
  `platform.idempotency.ttl_hours`.

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
- Verifikasi rantai (migrasi `0011`) mengikuti `prev_hash` dan tidak bergantung urutan `seq`, tetapi
  tetap menolak **cabang** (dua baris menunjuk pendahulu yang sama) — cabang hanya bisa dibuat dengan
  menulis langsung ke tabel tanpa trigger, dan penulis seperti itu sudah bisa menulis ulang ekor
  rantai (batas pertama di atas). Siklus tanpa genesis tidak terdeteksi, tetapi membuatnya butuh titik
  tetap fungsi hash, dan hash yang ditulis tangan tetap ketahuan lewat `row_hash_ok`. D-061 mencatat
  alasan dan alternatifnya.

## Invarian: urutan commit == urutan `seq` outbox

`platform.outbox.seq` dialokasikan saat **INSERT**, sedangkan commit bisa terjadi dengan urutan
berbeda. Pump realtime membaca tabel dengan kursor `seq` (`eventsAfter`), jadi bila urutan itu
terbalik, peristiwa yang commit belakangan akan **terlewat** — bukan sekadar tertunda.

Aturan penulis: **transaksi yang menulis peristiwa outbox wajib menulis entri audit lebih dulu, di
transaksi yang sama.** Trigger rantai audit memegang `pg_advisory_xact_lock(hashtext(
'platform.audit_log'))` **sampai commit**, sehingga penulis audit terserialkan dan urutan commit
outbox mengikuti urutan `seq` outbox-nya.

**Catatan `seq` audit (O-038, T-052)**: yang dijamin lock ini adalah urutan **commit** antar penulis
audit, **bukan** urutan `seq` audit. `seq` audit dialokasikan identity sebelum trigger mengambil
lock, jadi baris ber-`seq` lebih besar bisa commit lebih dulu — rantainya tetap linear, hanya
urutannya tidak mengikuti `seq` (direproduksi deterministik di `tests/itplatform.nim`, suite O-038).
Karena itu sejak migrasi `0011` verifikasi rantai mengikuti `prev_hash`, bukan
`lag(hash) OVER (ORDER BY seq)`, dan hasilnya tidak bergantung urutan commit. Untuk outbox tidak ada
yang berubah: penulis yang menulis audit lebih dulu sudah terserialkan sebelum baris outbox-nya
dialokasikan.

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
   Gerbang HTTP-nya dua tingkat (T-058, D-062): rute **daftar** memakai `authorizeAnyBranch` — izin
   cukup dipegang di suatu cabang, penyaringan per baris yang menentukan apa yang terlihat — dan rute
   yang menyentuh **satu** objek ber-cabang menambah `authorizedAtBranch` dengan cabang objeknya
   (pengajuan: `scopeId` ber-scope `BRANCH`; persetujuan: cabang baris yang diaktifkan, diperiksa
   sebelum alasan 409). `targetBranch = ""` selalu berarti institusi. Atribusi baris audit mengikuti
   **objek** yang disentuh, bukan cabang tugas pelaku, dan hanya terisi bila pengenalnya berbentuk
   uuid (O-017).
11. **`effectiveTo` hanya sah bila ada penerus** (O-043, D-046 butir 8): nilai ber-`effective_to` tidak
   boleh diaktifkan kalau tanggal berakhirnya tidak ditutup baris lain pada (key, scope) yang sama —
   kalau lolos, tanggal setelahnya tidak punya nilai berlaku (aplikasi gagal-cepat, spec §10.6) dan
   pemeriksaan lintas-parameter melewati tanggal itu (temuan review D-029). Vonisnya satu fungsi
   (`effectiveToGapProblem`) dan dipanggil dari **dua** pintu HTTP: pengajuan (400
   `effective_to_without_successor`) dan persetujuan (409, alasan sama) — persetujuan ikut memeriksa
   karena penerus bisa hilang di antara keduanya. Penerus = baris (key, scope) sama yang berlaku pada
   tanggal `effectiveTo` **dan** mulai pada atau setelah `effective_from` kandidat; batas kedua itu
   yang membuat kasus jahat ketahuan: persetujuan **memangkas** nilai ACTIVE yang mulai lebih awal
   (`supersedePreviousValues`), jadi nilai lama yang masih terbuka bukan penerus. Status yang
   dihitung: `ACTIVE`, `SUPERSEDED` (masih menjawab tanggal di dalam rentangnya, D-008), `PENDING`
   (saat nilai terbatas diajukan, penerusnya memang masih PENDING — urutan yang sah: ajukan penerus →
   setujui nilai terbatas → setujui penerus; menyetujui penerus lebih dulu memangkas nilai lama sampai
   `effective_from` penerus, sehingga rentang sebelumnya tidak bisa diisi lagi oleh baris baru karena
   bertabrakan dengan riwayat pangkasan itu, EXCLUDE); `DRAFT` tidak.

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

Catatan penempatan: `CloseLevel` hidup di `shared/kernel/dayclose.nim` (D-148). Kalender
menentukan level (`closeLevelsFor`), `daycloser` melaksanakannya; tipe bersama di kernel mencegah
dua modul menembus internal satu sama lain.

## Identitas, akses & sesi (T-006)

| Bagian | Berkas |
|---|---|
| Domain otorisasi | `domain/authz.nim` — kode izin `modul.resource.action`, branch scoping, `authorize` (satu cabang) + `authorizeAnyBranch` (set-level, T-058), SoD fail-closed, kebijakan sesi & password |
| Domain scope | `domain/scope.nim` — `ScopeRef` + konvensi lookup parameter (dipakai kalender & auth) |
| Hash password | `infrastructure/password_hasher.nim` — PBKDF2-HMAC-SHA256; hash token sesi (SHA-256) |
| Repo | `infrastructure/auth_repo.nim` — user/lockout, role/permission/SoD, sesi |
| Alur | `infrastructure/auth_service.nim` — `authenticate`, `sessionFor`, `touch`, `logout`, `logoutAll`, `authorizeUser`, `changePassword`, `bootstrapFirstAdmin`, `createUserWithRole`, `roleAssignmentProblem` |
| Migrasi | `0006_platform_auth.sql` (tabel) + `0008_platform_rbac_catalogue.sql` (katalog izin & role sistem) + `0010_platform_password_history.sql` (riwayat hash kata sandi) + `0028_platform_rbac_role_scope.sql` (kolom `role.scope` + izin baca parameter teller) + `0032_platform_rbac_admin_roles.sql` (peran admin sempit + pasangan SoD, T-118) |

Invarian tambahan:

12. **Password tidak pernah disimpan/di-log mentah**: DB hanya menyimpan
    `algo$iterasi$salt$digest`; parameter KDF ikut tersimpan supaya hash lama tetap valid.
13. **Kebijakan dari parameter** (spec §10.4): panjang minimum password, iterasi PBKDF2, batas
    gagal login, masa lockout, umur sesi idle/absolut — plus kelas karakter & riwayat kata sandi
    (invarian 21). Tidak ada default di kode.
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
20. **Kata sandi lama yang salah dihitung dan diaudit** (O-050, D-046 butir 8): `changePassword`
    memakai penghitung gagal yang **sama** dengan login (`recordLoginFailure` — angka dari parameter
    `max_failed_logins`/`lockout_minutes`), jadi tidak ada kebijakan kedua yang harus dijaga selaras;
    login yang berhasil mengosongkannya lagi. Jejaknya `user.password_change.failure` berisi alasan +
    keadaan penghitung, tidak pernah bahan kata sandi. Batasnya berarti: kunci akun berlaku juga
    untuk login berikutnya (kata sandi benar sekalipun), dan itu disengaja — pelaku yang memegang sesi
    sah tidak boleh bisa menebak kata sandi lama tanpa batas.
21. **Kata sandi baru: panjang + kelas karakter + riwayat; kedaluwarsa tidak ada** (O-052, D-046
    butir 8). `passwordProblems` (`domain/authz.nim`) menilai panjang, keragaman kelas
    (`platform.security.password_min_classes`: huruf kecil/besar/angka/simbol, `1` = hanya panjang),
    kesamaan dengan username, dan spasi; `changePassword` menambah larangan memakai ulang kata sandi
    yang **sedang berlaku** atau salah satu dari N terakhir (`password_history_count`) di
    `platform.user_password_history`. Tabel itu menyimpan hash saja (invarian 12) dan hanya yang
    **sudah digantikan**: hash aktif tetap tunggal di `app_user.password_hash`, dan barisnya
    dipangkas ke N terakhir di jalur tulis — tidak ada tabel yang tumbuh tanpa batas dan tidak ada
    tugas pembersih terpisah. Yang dijaga adalah **jendela** N terakhir, bukan larangan selamanya.
    **Kedaluwarsa kata sandi tidak dibangun** (D-046 butir 8): tidak ada kolom umur dan tidak ada
    penolakan karena umur — invarian ini yang menahan penambahannya kembali.
22. **Dua tingkat gerbang izin; atribusi cabang mengikuti objek yang disentuh** (T-058, D-062).
    `authorizeAnyBranch` menjawab "izin dipegang di suatu cabang" dan dipakai rute daftar
    (`GET /api/v1/params`, `GET /api/v1/audit`) yang hasilnya disaring per baris — menuntut satu
    cabang di situ akan menolak pembacaan yang sah. Aksi atas **satu** objek tetap memakai
    `authorize(targetBranch)` yang dipanggil begitu cabang objeknya diketahui. `targetBranch = ""`
    selalu berarti institusi, jadi grant khusus cabang tidak pernah diam-diam menjadi izin institusi
    (dan sebaliknya, grant institusi tidak menjadi izin cabang). `auditContextFor` mengisi
    `branchIds` dari objek itu — nilai parameter yang diajukan/disetujui, atau cabang yang dibaca
    untuk `param.read_cross_branch` — bukan dari cabang tugas pelaku: auditor cabang itu yang perlu
    melihat tindakan atas datanya, termasuk pembacaan dari pusat. Pengenal non-uuid membuat barisnya
    tetap tanpa cabang (kolomnya bertipe uuid, O-017) tanpa cast paksa — cast akan melempar dan
    mengubah permintaan sah menjadi 500. Langganan realtime sengaja **tetap** tingkat institusi
    (fail-closed) sampai peristiwanya disaring per cabang (O-070).
23. **Scope role ditegakkan saat pemberian, bukan ditebak dari cabang** (RBAC hardening).
    `platform.role.scope` bernilai `INSTITUTION` atau `BRANCH` (0028). Role `BRANCH` (hanya
    `teller`) wajib diberi **tepat satu** cabang berbentuk UUID; role `INSTITUTION` wajib
    **tanpa** cabang. `roleAssignmentProblem` memeriksa pasangan itu **sebelum** baris apa pun
    ditulis, dan `createUserWithRole` mengembalikan `false` bila tidak sah — tanpa itu role
    bercabang tanpa cabang mendapat grant global (melihat semua cabang), dan role institusi dengan
    cabang menghasilkan akun mati (rute institusi mengotorisasi pada `targetBranch = ""`). Bila
    pemberian role gagal **setelah** pengguna disisipkan, `createUserWithRole` melempar galat
    (bukan `false`) supaya pembungkus transaksi `withRoleDb` me-rollback baris itu — `withTx`
    COMMIT begitu `body` kembali normal, jadi `false` akan meng-commit akun setengah jadi.
    Siklus hidup (assign/revoke role, disable/enable/unlock) dilakukan lewat `ctl` dengan audit +
    pencabutan sesi dalam satu transaksi; `revoke-role`/`disable-user` menolak bila operasinya
    menyisakan **nol** pengguna aktif yang bisa mengelola pengguna (`platform.user.manage`, T-118).

Catatan: alur auth tinggal di `infrastructure` (butuh DB). Saat port/use case lapisan
`application` lahir (pola T-016), isi `auth_service.nim` pindah ke `application/`.

## Administrasi pengguna (T-117)

| Bagian | Berkas |
|---|---|
| Layanan | `infrastructure/auth_service.nim` — `grantUserRole`, `revokeUserRole`, `disableUserAccount`, `enableUserAccount`, `unlockUserAccount` (+ `locksOutLastAdmin`); aturan siklus hidup **satu definisi**, dipakai `ctl` dan rute HTTP |
| Repo | `infrastructure/auth_repo.nim` — `listUsers`, `roleGrantsOfUser`, `listRoles`, `countUsersWithRole`, dan (T-118) `roleGrantsPermission`, `userHasPermission`, `userHasPermissionExcludingRole`, `countActiveUsersWithPermission` |
| HTTP | `apps/api/src/handlers_users.nim` — `GET /api/v1/users`, `GET /api/v1/roles`, `POST /api/v1/users/{userId}/roles`, `DELETE …/roles/{role}`, `POST …/disable|enable|unlock` |
| Migrasi | `0029_platform_rbac_user_admin.sql` — izin `platform.user.manage` untuk `platform_admin` |

Izin `platform.user.manage` adalah aksi **tingkat institusi**: kedua gerbang `requirePermission`
(izin dipegang) **dan** `authorizedAtBranch(..., "")` (grant tanpa batas cabang) harus lolos. Audit
memakai action yang sama dengan `ctl` (`user.role_grant`, `user.role_revoke`, `user.disable`,
`user.enable`, `user.unlock`) dengan aktor dari sesi; penolakan dipetakan ke 409 dengan
`params.reason` stabil (`last_admin`, `sod_conflict`, `already_granted`, `not_granted`,
`not_inactive`, `not_locked`). **HUMAN-REVIEW-REQUIRED** (administrasi pengguna/RBAC, AGENTS.md §8).

### Peran admin sempit & penjaga pengelola terakhir (T-118, K-1(b)/K-2(a)/K-7(a))

Sampai `0029` hanya `platform_admin` yang memegang seluruh izin, sehingga SoD tidak bisa ditegakkan
(memasangkan konflik ke peran wildcard itu akan melumpuhkannya sendiri). `0032` memecah admin menjadi
peran sempit dan menyemai pasangan konflik antar peran itu:

| Role | Izin inti | Fungsi |
|---|---|---|
| `ops_admin` | `platform.user.manage`, `platform.param.read`, `platform.audit.read`, `party.party.read`/`create`, `deposit.account.manage`/`read`, `product.catalog.read`, `ledger.coa.read`/`period.read`, `teller.vault.read`, `teller.vault.submit`, `platform.branch.read` | administrasi akun/anggota/rekening |
| `ledger_admin` | `ledger.coa.manage`, `ledger.period.manage`, `ledger.journal.read`/`reverse`, `product.catalog.manage`, `platform.param.read`, `platform.branch.read` | pembukuan, periode, COA, pembalik |
| `cash_admin` | `teller.vault.submit`/`approve`, `teller.vault.read`, `platform.branch.read` | penyediaan kas/vault cabang |
| `product_maker` | `product.catalog.manage`, `product.catalog.read` | pengaju katalog produk (checker: `product_checker`) |

Pasangan `platform.role_conflict` (kanonik `a < b`): wajib `product_checker`/`product_maker` dan
`cash_admin`/`ledger_admin`; *nice to have* `ledger_admin`/`ops_admin`, `ledger_admin`/`teller`,
`cash_admin`/`teller`. **`platform_admin` tetap ada sebagai break-glass** — bukan peran harian, dan
sengaja tidak dipasangkan konflik agar override darurat tetap bisa dipakai (wajib beralasan + audit +
laporan ke pengurus; memo T-118 §3).

Penjaga penguncian-keluar (K-7(a)) bekerja pada **izin** `platform.user.manage`, bukan satu kode
role: `locksOutLastAdmin(db, user, roleBeingRevoked)` menolak `revoke-role`/`disable-user` bila
operasinya menyisakan nol pengguna **ACTIVE** pemegang izin itu (`platform_admin` dan `ops_admin`
sama-sama dihitung). Pada `revoke-role`, role yang dicabut hanya berpengaruh bila ia memang memberi
izin tersebut **dan** menjadi satu-satunya jalur pengguna ke izin itu. Satu definisi, dipakai `ctl`
dan rute HTTP; `reason` stabil `last_admin` (kode keluar 3 / HTTP 409) tidak berubah.

## Master cabang (D-130)

| Bagian | Berkas |
|---|---|
| Migrasi | `0030_platform_branch_master.sql` — tabel `platform.branch` + cabang pilot `001` (`b0000000-…-001`) |
| Repo | `infrastructure/branch_repo.nim` — `branchById`, `branchByCode`, `insertBranch`, `listBranches`, `validBranchCode` |
| ctl | `apps/api/src/main.nim` — `create-branch --branch-code=<3 digit> --branch-name=<nama>` (audit `branch.create`, kode keluar 3 untuk kode tidak sah/duplikat) |

Kode cabang **tidak boleh diubah** begitu ada nomor rekening yang memakainya: nomor rekening adalah
identitas bisnis (D-130). Perbaikan kode hanya lewat migrasi + analisis data. **Baca** cabang lewat
HTTP sudah ada — `GET /api/v1/branches` (izin `platform.branch.read`, `0037`/T-121); membuat atau
mengubah cabang tetap lewat `ctl create-branch` (O-101 sebagian selesai).

## MFA TOTP (T-046, spec §13/§18.2)

| Bagian | Berkas | Catatan |
|---|---|---|
| Primitif | `shared/platform-lib/crypto/totp.nim` | base32 RFC 4648, HOTP RFC 4226, TOTP RFC 6238, `otpauthUri`; tanpa I/O dan tanpa waktu implisit |
| Repo | `infrastructure/mfa_repo.nim` | `mfaOf`, `upsertPending`, `activateMfa`, `recordUsedStep`; ciphertext diperlakukan buram (tidak mendekripsi) |
| Layanan | `infrastructure/mfa_service.nim` | `mfaSettingsOf` (kebijakan), `mfaStatusOf`, `startEnrolment`, `confirmEnrolment` + audit |
| Skema | `migrations/0012_platform_user_mfa.sql` | satu baris per akun, status `PENDING`/`ACTIVE`, `last_used_step` |
| HTTP | `apps/api/src/handlers_mfa.nim` | `GET /api/v1/auth/mfa`, `POST …/mfa/enrolment`, `POST …/mfa/verify` — self-service, tanpa izin baru |

Invarian tambahan:

15. **Rahasia TOTP tidak pernah disimpan sebagai plaintext** dan tidak pernah bisa dibaca ulang lewat
    API: `encryptField` (AAD = nama tabel `user_mfa`) saat pendaftaran, `decryptField` hanya untuk
    memverifikasi. Tanpa `KRAN_KEK_FILE` rutenya menolak (501) alih-alih menulis apa pun.
16. **Digit dan periode tersimpan per baris** dan dipakai saat verifikasi — parameter yang berubah
    hanya memengaruhi pendaftaran **baru**. `drift_steps` tetap parameter: itu toleransi jam, bukan
    bentuk rahasia.
17. **Enrolment tidak mengganti faktor `ACTIVE`** (409 `mfa_already_active`); hanya `PENDING` yang
    bisa ditimpa. Faktor yang sudah aktif adalah keadaan yang pemulihannya butuh alur sendiri —
    lihat O-071.
18. **`mfa.enabled` default `false`**, dan gerbang itu diputuskan **sebelum** apa pun menyentuh
    kripto/data: selama mati, ketiga rute menjawab 403 `mfa_disabled` dan tidak ada baris yang lahir —
    termasuk di instalasi tanpa `KRAN_KEK_FILE` (periksa keyring **setelah** gerbang fitur) maupun di
    instalasi yang nilai `platform.security.mfa.*`-nya belum tersemai (saklar dibaca lewat
    `activeValueOpt`: tidak ada nilai → fitur mati, bukan 500). Pemanggil karena itu tidak bisa
    menyimpulkan status konfigurasi server dari beda 403/501/500 pada rute ini. Nilai kebijakan lain
    hanya dibaca setelah saklarnya hidup. Parameter MFA dibaca lewat `mfaSettingsOf` saja — jalur
    login (`settingsOf`) tidak bergantung padanya, jadi seed MFA yang belum dijalankan tidak bisa
    mematikan login.
19. **Rahasia, kode, dan URI tidak pernah masuk audit**: hanya `auth.mfa.enrol`,
    `auth.mfa.verify`, `auth.mfa.verify_failure` beserta bentuk pendaftaran (status, digit, periode).
20. **Respons ditulis setelah transaksi selesai**, tidak dari dalam closure `withDbTx`: COMMIT yang
    gagal setelah respons terkirim akan mengirim respons kedua di koneksi yang sama. Respons yang
    memuat rahasia (201 pendaftaran) memakai `Cache-Control: no-store` — rahasia TOTP adalah
    kredensial berumur panjang.

Catatan: tugas wajib-ganti-kata-sandi dan MFA keduanya **tidak** memakai `requirePermission` —
alasan yang sama (pengguna harus bisa menyelesaikan keadaan akunnya sendiri, termasuk saat ia belum
boleh memakai rute ber-izin).

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
