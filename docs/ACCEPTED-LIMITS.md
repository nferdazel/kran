# Batas yang diterima — Fase 0–2

Dokumen ini adalah **register keputusan**, bukan daftar keinginan. Aturannya satu: setiap batas harus
punya (a) dampak nyata, (b) cara mendeteksinya, dan (c) pemilik — fase atau task yang menanganinya.
Kalau salah satu tidak ada, itu bukan batas yang diterima melainkan pekerjaan yang terlupa.

Alasan dokumen ini ada: "Fase 0 tanpa cela" bukan sesuatu yang bisa dibuktikan siapa pun. Yang bisa
dibuktikan adalah **tidak ada celah yang diketahui pada jalur yang diperiksa**, dan setiap hal yang
belum ditangani tercatat beserta cara melihatnya. Register ini adalah bagian kedua dari kalimat itu.

## 1. Batas yang memang milik fase lain (tidak dipaksakan masuk fase berjalan)

| Batas | Dampak nyata | Cara mendeteksi | Pemilik |
|---|---|---|---|
| Metrics/observability belum ada (Prometheus-style: latensi, error rate, pool PG, antrean outbox, durasi task day-close) | Tidak ada pengukuran berkelanjutan; operator hanya punya log terstruktur | `/healthz`, `/readyz`, log JSON, dan kueri SQL manual | Fase 9 (spec §22, §23) |
| ~~Freeze katalog produk sebelum T-086~~ **DITUTUP (T-086/D-099, 23 Okt 2026)**: maker-checker versi produk aktif, dan contract `product/0006` (T-090/D-119) mencabut jaring rollback lama | Sisa yang nyata: satu akun tidak bisa menyetujui produknya sendiri, jadi pilot wajib punya operator kedua (`product_checker`) | 409 `self_approval` saat akun yang sama mencoba approve | T-086, T-090, D-099, D-119 |
| Freeze gate day-close | Deploy tidak bisa diblokir karena EOD berjalan; `ctl daycloser-status` selalu "belum ada" | jalankan `ctl daycloser-status` — nilainya selalu 3 sampai `daycloser` ada | Fase 3 (framework `daycloser`); O-013 |
| Frekuensi uji restore & latihan DR | Backup hanya terbukti bisa dipulihkan pada drill terakhir, bukan terus-menerus | **Drill pertama SELESAI (21 Okt 2026, O-007)**: restore dump harian ke DB latihan, hitungan cocok, rantai audit utuh. Jadwal bulanan ada di `docs/runbooks/restore-drill.md`; kepatuhan jadwal di luar repo | Di luar repo (akses server); O-007, `docs/runbooks/restore-drill.md` |
| Target performa (spec §1.4: EOD 100k rekening + 50k pinjaman < 30 menit) | Belum ada bukti skala; angka target belum pernah diuji | belum ada benchmark | Fase 3 (day-close) + Fase 9 |
| Multi-instance / HA | Satu proses = satu titik gagal | arsitektur: satu biner, satu pool, satu pump | Fase 9 (cutover §23) |
| MFA belum **diaktifkan** (kerangka ada) & SoD baru sebatas pasangan tersemai | Kontrol akses harian = kata sandi + RBAC + audit; faktor kedua belum diminta saat login (`mfa.enabled = false`) dan pemisahan tugas hanya efektif bila akun per peran benar-benar dipakai, bukan satu `platform_admin` | `platform.param_value` (`mfa.enabled`), `platform.user_role` (berapa akun memegang `platform_admin`), `platform.role_conflict` (pasangan SoD) | O-015/O-071 (aktivasi MFA), D-113/D-131 (SoD), O-102 |

## 2. Batas teknis yang diterima setelah batch "Fase 0 tahan banting"

| Batas | Dampak nyata | Cara mendeteksi | Pemilik |
|---|---|---|---|
| Build API belum reproducible: `nimble install -d` tanpa lockfile mengambil versi dependensi saat build | Dua build dari commit yang sama bisa memakai versi pustaka berbeda, jadi biner tidak identik | bandingkan sha256 biner gate di `$APP_DIR/releases.txt` antar-build untuk rev yang sama | T-131 (OPS-8); perlu `kran.lock`/vendor |
| Delivery webhook bisa diputar ulang (HMAC GitHub menutup body, bukan waktu kirim) | Deploy ulang tidak disengaja; tanpa penjaga, tiap replay membangun + restart layanan | penjaga rev sama di `deploy-vps.sh` (`skip: rev … sudah ter-deploy`); `KRAN_FORCE_DEPLOY=1` hanya untuk deploy ulang yang disengaja | T-131 (OPS-10) |
| Tidak ada tag image per commit (hanya `:local`/`:prev`) | Artefak per rilis tidak disimpan; hanya satu versi sebelumnya tersedia untuk rollback | `podman images localhost/kran-api`; manifest `$APP_DIR/releases.txt` mencatat rev + image ID + sha256 biner | T-131 (OPS-2/OPS-8), kontrak emas §3.4 |
| Rollback layanan tidak mengembalikan skema | Binary lama berjalan di atas skema yang sudah maju; contract yang terlanjur jalan tidak bisa dibatalkan oleh `rollback.sh` (hanya image yang kembali) | `--role=migrate --check` setelah rollback; bandingkan `platform.schema_migration` dengan commit yang di-deploy | T-035/T-040, T-090, D-119 |
| Migrasi **contract** sudah jalan di produksi (`product/0006`, 23 Okt 2026), tetapi **`--down`** belum pernah dilatih pada data nyata | Rollback skema belum pernah diuji di server; pasangan `.down.sql` belum ada untuk migrasi nyata | `--role=migrate --check` setelah rollback; `SELECT filename FROM platform.schema_migration` untuk melihat contract yang terpasang; latihan `--down` = T-013 | T-035, D-040 |
| Job CI `traceability` belum ada | Matriks requirement ↔ kontrol/test tidak dihasilkan otomatis; ketertelusuran masih manual di `docs/spec` + `docs/compliance` | job `db-tests` **sudah ada** (`postgres:18`, migrasi + `./task test`); `traceability` belum — lihat `docs/ci-jobs.md` | O-027 |
| Antrean kirim realtime per koneksi tidak dibatasi | Klien lambat menambah pemakaian memori proses | pantau RSS; peristiwa hilang ditutup resume token | O-028 |
| Peristiwa outbox yang membuat `oldestUndeliveredSeconds` kehilangan kursor (baris kursor dihapus) diperlakukan "dari awal" | Usia lag bisa terbaca besar sesaat walau konsumen sebenarnya tidak tertinggal | baris outbox tidak pernah dihapus jalur produksi; reset kursor hanya di uji | T-041 |
| Probe migrasi `/readyz` bergantung pada mount `modules/` di container (`--root=/monorepo`); bila mount hilang, probe melaporkan "akar migrasi tidak tersedia" dan **tetap 200** | Skema tidak terverifikasi walau health gate hijau | `checks[]` di `/readyz` memuat `migrations` dengan `detail` "akar migrasi tidak tersedia"; volume di `ops/systemd/kran-api.container` | T-041/O-019; T-067/D-066 |
| SIGTERM: koneksi yang belum masuk handler tetap terpotong; soket realtime ditutup oleh keluarnya proses | Permintaan yang belum masuk handler bisa gagal saat deploy; klien WS menyambung ulang | log `permintaan berjalan selesai (drain)` / `N permintaan masih berjalan` | T-032, T-042 (diterima; `close()` tidak dipanggil jalur produksi — teardown in-process butuh server dibangun+disajikan di thread yang sama, lihat O-025) |
| Jendela staleness izin realtime | Setelah izin dicabut, data masih bisa terkirim sampai satu interval pemeriksaan berakhir | parameter `sessionRecheckSeconds` (0 = setiap putaran pump) | T-030 |
| Validasi koneksi pool menambah satu perjalanan bolak-balik per peminjaman dari idle | Latensi per permintaan naik sedikit | `KRAN_DB_VALIDATE_ON_ACQUIRE` (matikan = koneksi mati di server tidak diganti otomatis) | T-033 |
| Deadline DB berlaku per **blok kerja** (default 20 s), bukan per kueri: blok `withTx` dengan banyak statement yang totalnya melebihi anggaran akan gagal (server me-ROLLBACK) | Use case panjang (rekap/import) harus muat dalam anggaran atau menaikkan `KRAN_DB_QUERY_DEADLINE_MS` | `PoolError` "blok kerja DB melewati batas …"; log galat menyebut batas | T-065, D-065 |
| Jalur `pool.acquire()` langsung (pump `LISTEN` yang hidup selama proses) tidak memakai deadline blok | Bila perantara membeku saat pump menunggu, pump bisa menggantung sampai keepalive | pump tidak mengirim heartbeat; `pumpLastReadyNs` tidak maju, readiness realtime melaporkan degraded | T-065; pump T-029 (desain koneksi panjang) |
| Batas DB memakai satu koneksi dari pool setiap kali terpicu (dibuat ulang saat dibutuhkan) | Sesaat setelah kejadian, kapasitas pool berkurang satu | `statsOf().created` turun; koneksi baru dibuat pada peminjaman berikutnya | T-065 |
| Biaya KDF tiruan mengikuti parameter iterasi **saat ini** | Akun lama dengan jumlah iterasi berbeda tidak setara biayanya | bandingkan waktu respons login akun tak dikenal vs akun wajar | T-028 |
| ~~Percobaan kata sandi lama di `/auth/password` belum dibatasi/diaudit~~ **DITUTUP (T-051/D-057, 21 Okt 2026)**: penghitung gagal yang sama dengan login + audit `user.password_change.failure` (tanpa bahan kata sandi) | Sesi yang sedang berjalan tidak dicabut setelah kata sandi berubah (disengaja, D-057 butir 4) | audit `user.password_change.failure`; akun terkunci → login 403 `locked` | D-057 |
| PB lintas cabang diatribusikan hanya ke cabang sumber (audit, jurnal, event) | Kedua baris D/K 201 ber-`branch_id` sumber, jadi GL 201 cabang tujuan tidak mencerminkan kredit sementara subledger rekening naik: neraca cabang vs subledger menyimpang sebesar nominal PB | query `deposit.transfer` per `branch_id` kedua akun dibandingkan `journal_line` 201 per cabang; belum ada laporan GL per cabang | Fase 3; T-101 menutup rekonsiliasi cache, bukan GL per pemilik (D-124) |
| Cache saldo `deposit.account_balance` bisa menyimpang dari baris mutasi (kas + PB) | Saldo teller dari cache; restore parsial atau bug tulis membuat saldo tidak cocok dengan baris sumber. Perbandingan terhadap GL per rekening **tidak mungkin** selama liabilitas dipool di akun `201` (PB net-nol) | **DITUTUP SEBAGIAN (T-101, 24 Okt 2026)**: `ctl reconcile-deposits [--branch]` membandingkan cache dengan `deposit.transaction` + `deposit.transfer` (exit 1 bila ada selisih, termasuk cache hilang). Belum dijadwalkan otomatis. Pembalik jurnal subledger kini **ditolak** 409 `journal_owned_by_subledger` (T-123/D-135), jadi selisih tidak bisa lagi lahir dari koreksi lewat buku besar | Fase 3 (day-close) |
| Jurnal pemindahbukuan (PB, `DepositTransferred`) **net-nol di GL**: kedua sisinya akun `201` yang sama | Buku besar tidak membedakan pemilik rekening; `journal_line` saja tidak cukup merekonstruksi saldo per rekening dari PB, dan GL per pemilik anggota belum ada | perpindahan per rekening ada di `deposit.transfer` (sumber & tujuan); bandingkan saldo `deposit.account`/`account_balance` dengan `deposit.transfer` + jurnal 201 | Fase 3; `modules/deposit/MODULE.md` |
| Hanya pengenal cabang berbentuk **uuid** yang bisa diatribusi ke `platform.audit_log.branch_id` | Entri audit untuk cabang ber-id teks (id warisan/seeder) tetap `branch_id` NULL, jadi pemisahan audit per cabang tidak berlaku untuknya; pengenalnya tetap utuh di `resource_id`/payload | `SELECT branch_id FROM platform.audit_log WHERE action = 'param.submit' AND resource_id = ...` → NULL; diuji eksplisit di `itapi_auth` (suite scoping cabang, test pengenal non-uuid) | O-017; T-058, D-062 |
| Topik realtime `param.changed` hanya dibuka untuk grant **tanpa** batas cabang | Pengguna yang izinnya khusus cabang tidak menerima peristiwa parameter sama sekali (fail-closed, bukan bocor); membukanya tanpa penyaringan justru mengirim peristiwa semua cabang | langganan topik gagal pada klien ber-grant khusus cabang; `topicsAllowedFor` memakai `authorized` tingkat institusi | O-070; T-058, D-062 |
| Penerus yang ditolak **setelah** nilai ber-`effective_to` disetujui meninggalkan celah (tidak ada nilai berlaku setelah tanggal itu) | Aplikasi gagal-cepat saat startup (`missingActiveKeys`); pemulihannya dengan mengajukan + menyetujui penerus baru | pemeriksaan ulang saat persetujuan menutup kasus penerus hilang **sebelum** persetujuan (`itapi_auth`: 409); celah yang lolos tetap terdeteksi startup check O-057 | D-056; O-043/O-065 |
| Regulasi spec §4 bertanda `V?`/`V!` belum terverifikasi | Pasal/angka bisa berubah; yang bergantung padanya belum final | penanda `NEEDS-COMPLIANCE-REVIEW` di kode/seed/docs | O-001 |
| Belum ada kontrak-fuzzing (`schemathesis`) dan visual regression | Cakupan uji kontrak/visual lebih sempit daripada rencana spec | lihat daftar uji; parity kontrak diuji lewat `tcontract`/`itapi` | O-026, O-022 |
| Lint statis generik (ESLint) belum ada — bagian a11y **sudah tertutup** | Aturan `svelte/*` non-a11y dan `typescript-eslint` belum menegakkan apa pun; diagnostik a11y kompilator kini memblokir lewat `svelte-check --fail-on-warnings` | diputuskan 17 Okt 2026 (D-053) untuk dikerjakan bersama T-012 | O-023, T-057 |
| Tag image lama yang masih direferensikan container berhenti tidak bisa dihapus `podman rmi` | Tag itu tetap ada sampai container berhenti dibersihkan; pertumbuhan disk tertahan, bukan nol | baris `WARN: gagal menghapus …` di `deploy.log`; `podman ps -a` | T-069 |
| ~~`KRAN_KEK_FILE` belum di-mount ke container~~ **DITUTUP (24 Okt 2026)**: produksi me-mount berkas KEK mode 600 (`/run/secrets/kran-kek.key`) untuk `kran-api` dan `kran-worker`; env dan mount didokumentasikan di `ops/systemd/*.container` + `ops/env/kran-prod.env.example` | Sisa: rotasi KEK masih dilarang sampai `ctl reindex-blind-index` ada (D-111) | `podman inspect kran-api --format '{{range .Mounts}}{{.Destination}} {{end}}'` memuat berkas KEK | D-066, D-111, O-071 |
| ~~Kas teller/vault tanpa jurnal GL~~ **DITUTUP (T-118/D-132/D-134, 24 Okt 2026)**: buka/tutup sesi, selisih kas, top-up vault yang disetujui, dan saldo awal vault (`D 101.1 / K 203`, `ledger/0036`) kini berjurnal | Rekonsiliasi resmi memakai agregat: `teller.vault` = GL `101.1` + GL `101` (legasi 2.700.000, tidak bisa dipindah karena `101` non-postable dan ledger immutable). Yang tersisa hanya batas pemetaan: `101.1`/`101.2`/`101.9`/`203` adalah usulan pilot (`NEEDS-COMPLIANCE-REVIEW`, REG-011), bukan kutipan SAK EP/PSAK | bandingkan `teller.vault` dengan `101.1 + 101` per cabang saat tidak ada sesi OPEN; saldo `101.2`/`101.9` kembali nol setelah semua sesi tutup | T-118; O-097/O-105 (tertutup), REG-011 |
| ~~Top-up vault tanpa batas nominal~~ **DITUTUP (D-133, 24 Okt 2026)**: plafon per pengajuan = parameter `teller.vault.limit_topup_per_request` (pilot Rp25.000.000); setor/tarik/opening float punya plafon sendiri | Angka plafon adalah kebijakan pilot (`NEEDS-COMPLIANCE-REVIEW`), bukan regulasi, dan belum mencakup akumulasi harian/plafon saldo vault | 409 `topup_exceeds_limit`/`cash_limit_exceeded`; nilai di `platform.param_value` | D-133; O-099 tertutup |
| Vault harus dibuat lewat seed/runbook sebelum bisa diajukan top-up | Tanpa baris `teller.vault`, pengajuan → 404 `vault_not_configured` (tidak ada pembuatan baris lewat API); operasi awal menyentuh DB langsung | 404 `vault_not_configured` pada `POST /teller/vault/topups`; `SELECT balance FROM teller.vault` | T-107/T-118; `modules/teller/MODULE.md` §Operasional |
| Rollback binary ke `:prev` setelah T-093b (tanpa gerbang sesi) meninggalkan jendela: transaksi tunai tidak menulis `cash_movement` sementara sesi masih `OPEN` | `expected_cash` saat tutup tidak memuat transaksi jendela rollback → variance rapor palsu | bandingkan `COUNT(teller.cash_movement)` dengan `COUNT(deposit.transaction)` per sesi/business date setelah rollback | T-093 (mitigasi: tutup semua sesi / rekonsiliasi manual sebelum rollback) |
| `expected_cash` hanya benar bila **setiap** transaksi tunai menulis `teller.cash_movement` | Kalau gerbang sesi (093b) dilewati (mis. binary lama), arus laci tidak lengkap dan variance salah tanpa error | paritas `COUNT(teller.cash_movement)` vs `COUNT(deposit.transaction CASH_*)` per sesi; uji `itapi_teller` (gate) + `itsession` (movement) | T-093; `modules/teller/MODULE.md` |

## 3. Yang **tidak** diklaim

- **Bukan "tanpa bug".** Yang dibuktikan: gate hijau berulang, dan setiap perbaikan penting punya uji
  yang **gagal** bila perbaikannya dibalik (lihat §4). Itu batas bukti yang jujur.
- **Stabilitas belum diuji pada beban produksi.** Gate ini menjalankan permintaan serial/rendah;
  uji paralel yang ada (8 thread pada pool kecil, 8 klien realtime) membuktikan kebenaran, bukan
  kapasitas.
- **Rollback belum pernah dilatih di server.** Deploy sudah berjalan berulang di produksi
  (`deploy.log`, 19 Okt 2026); jalur auto-rollback dan `ops/scripts/rollback.sh` baru dibuktikan
  lewat harness (T-068), belum pada layanan nyata. Rehearsal-nya pekerjaan tersendiri (T-013).
- **Gate hijau bukan jaminan bebas flake.** Dua kejadian yang **belum dijelaskan**, dicatat apa adanya di
  `docs/tasks/T-031.md`: (a) e2e login menggantung — 15 Okt (4 test, 7,5 menit) dan **berulang** 16 Okt
  (1 test, 9,2 menit), log API bersih; (b) 2 dari 200 iterasi stress pool melempar pengecualian, lalu
  gate ulang gagal karena **tunnel DB dev mati** (`Connection refused`; tunnel hidup lagi setelah dibuka
  ulang). Yang dikerjakan: uji stress pool kini mencetak nama+pesan galatnya (tanpa melunakkan hitungan
  yang diuji), bukan menaikkan batas tunggu atau melewatinya.
- **Gate lokal lewat tunnel sensitif latensi; gate yang otoritatif adalah CI.** 17 Okt 2026 (saat
  mengerjakan O-043): `./task test` gagal di `itpool` dan `./task e2e` gagal 2 spec, sementara CI hijau
  pada commit yang berjalan. Terukur saat itu: RTT ke VPS ~150 ms dan tiap pemanggilan `psql` lewat
  tunnel ~0,8 s (10 pemanggilan ≈ 8,0 s) — sedangkan `itpool` menunggu koneksi maksimum 15 s dengan
  8 thread / poolSize 3, dan Playwright menunggu 10–30 s. **Kontrol yang dijalankan**: perubahan O-043
  di-`git stash`, lalu pada pohon bersih `itpool` **gagal dengan pola sama** dan `e2e` malah **lebih
  buruk** (4 gagal vs 2) → bukan regresi kode. Karena itu bukti gate penuh diambil dari CI: job
  `db-tests` dan `web-e2e` memakai Postgres/browser di runner sendiri, bukan tunnel.
- **Test yang dijalankan di luar gate penuh bisa gagal tanpa ada yang salah pada kode.** Dua contoh nyata
  (16 Okt, saat mengerjakan T-035): `itapi_roles` butuh nilai parameter yang disemai `itapi_auth` yang
  berjalan lebih dulu; dan `./task e2e` sendirian menumpuk jejak audit sehingga locator `exact` kena
  *strict mode* — dalam gate, `itplatform` menjatuhkan schema `platform` lebih dulu sehingga e2e mulai
  bersih. Jadi sebelum menyebut sesuatu "flake kode": periksa dulu apakah keadaannya disiapkan fase lain.

## 4. Bukti historis (tanggal eksplisit; angka terkini ada di `docs/PROGRESS.md`)

- `./task ci-repeat 3` (gate kestabilan, T-031): hijau **3 putaran berturut-turut** atas tree final
  T-037 — 464 `[OK]` per putaran (1392 total) dan 23 uji e2e per putaran. Satu flake e2e sebelumnya
  (4 test login menggantung; tidak berulang) tercatat jujur di `docs/tasks/T-031.md`.
- Tujuh perbaikan terbukti **diskriminatif** lewat mutasi (uji gagal saat perbaikan dibalik):
  1. T-028 — hash tiruan PBKDF2 dimatikan;
  2. T-029 — penyambungan ulang pump dihapus;
  3. T-029 — titik mulai (`lastEventId`) di-reset saat menyambung ulang;
  4. T-030 — penutupan langganan saat izin dicabut dihapus;
  5. T-032 — drain dimatikan;
  6. T-033 — validasi nyata koneksi pool dimatikan;
  7. T-065 — batas blok kerja DB dinaikkan 700 ms → 3000 ms (uji gagal: `elapsed 3,03 s`).
- Uji yang **bukan** bermutasi dinyatakan apa adanya di task-nya sendiri (T-033 paralel pool,
  T-034 penjaga regresi Mummy).

## 4a. Simpanan koperasi (T-111) — batas yang disengaja

- `product.savings_kind` hanya **klasifikasi** produk/rekening. Aturan iuran pokok/wajib (nominal
  tetap, sekali/periodik, auto-debit, tunggakan, refund saat keluar anggota) **belum ditegakkan**;
  itu Fase 5 (coop pack) dan butuh keputusan AD/ART.
- Setoran POKOK/WAJIB diposting ke akun ekuitas provisoris `301.1`/`301.2`. Nomor akun dan
  klasifikasi ekuitas vs liabilitas **belum final**; wajib `NEEDS-COMPLIANCE-REVIEW` (REG-101)
  sebelum laporan/pilot data nyata.
- Tarik dan PB dari rekening POKOK/WAJIB diblokir 409; PB lintas jenis diblokir 409. Alur keluar
  anggota/refund belum ada.
- Produk lama tidak di-backfill: `savings_kind = NULL` berarti belum terklasifikasi dan diperlakukan
  seperti simpanan generik.
- **Rollback layanan**: image sebelum T-111 tidak mengirim `savingsKind` dan tidak punya guard PB.
  Selama rollback, setoran POKOK/WAJIB kembali ke `201` dan PB keluar dari POKOK/WAJIB bisa lolos;
  migrasi expand tidak membatalkan ini. Jangan rollback melewati rilis T-111 tanpa rekonsiliasi GL.
- Daftar rekening per party dibatasi **200 baris pertama** (urutan nomor rekening) **sebelum**
  gerbang cabang; party dengan lebih dari 200 rekening lintas cabang bisa kehilangan rekening
  berizin yang nomornya lebih besar. Batas wajar untuk pilot; bila perlu, saring cabang di SQL.

## 4b. Cetak Fase 2 (T-094) — browser print, bukan PDF server

- Slip dan statement dicetak dari browser (`@media print` + `window.print`). **Tidak ada** PDF
  server, penyimpanan PDF, hash, retensi, atau tanda tangan; ADR-013b (Typst di worker) ditunda.
- Bukan pengganti buku tabungan dot-matrix/passbook. Layout bisa berbeda antar printer/browser;
  header/footer browser (URL/ID) tidak bisa dipaksa hilang lewat CSS.
- Tidak ada audit cetak: klik Cetak bukan bukti tercetak, dan dialog bisa dibatalkan. Tidak ada
  kop/identitas lembaga (belum ada master cabang/parameter `institution.*`) — slip bersifat internal.
- Statement adalah **subledger** (transaksi tunai + PB), bukan rekonsiliasi GL, dan **tanpa saldo
  berjalan per baris**. Batas 500 baris ditolak (bukan dipotong); pemilik bisa mempersempit rentang.
- PII di kertas/spool di luar kendali sistem: dokumen memuat nomor rekening, nominal, dan narasi
  apa adanya. Jangan menyimpan hasil cetak sebagai PDF di server.
- Template cetak ada di kode, bukan DB (deviasi sadar spec §16.2); parameterisasi letterhead = task
  terpisah.

## 4c. Permukaan operator pilot (23 Okt 2026) — batas yang diterima

Batas berikut **hanya berlaku untuk pilot saat ini** (1 koperasi, 1 cabang, data sintetis; O-004/D-046).
Ia bukan klaim pekerjaan selesai. **Diperbarui 24 Okt 2026:** permukaan operator yang dulu hanya CLI
sekarang sudah punya UI (T-115 buka rekening, T-116 administrasi buku besar, T-117 pengguna/peran,
T-121 top-up vault), jadi batas "tidak ada UI" di bawah sudah tidak berlaku; yang tersisa hanya
keputusan tata kelola (O-102).

- ~~Tidak ada UI top-up vault (API-nya ada)~~ **DITUTUP (T-121, 24 Okt 2026)**: `/app/vault` mengajukan
  dan menyetujui top-up; `/app/ledger` menangani akun/COA/periode, `/app/users` menangani pengguna/peran,
  dan pembukaan rekening ada di `/app/deposit`. Setup awal (akun pertama, reset sandi) tetap lewat
  `kran-api --role=ctl`. Pemilik: T-115…T-117, T-121.
- **Top-up vault: maker-checker lewat API dan UI.** `POST /teller/vault/topups` (izin
  `teller.vault.submit`) hanya membuat pengajuan; `.../{requestId}/approve` (izin
  `teller.vault.approve`) oleh akun lain menulis saldo + jurnal `D <teller.vault.cash_account> / K
  <akun sumber>`. UI `/app/vault` memisahkan peran pengaju dan penyetuju, tetapi keduanya tetap harus
  akun berbeda (409 `self_approval`). Plafon per pengajuan sudah ada (D-133). Cara deteksi: `teller.vault_topup_request`
  (status + `decided_by`), `platform.audit_log` (`teller.vault.topup.submit`/`.approve`), event
  `TellerVaultTopUpRequested`/`TellerVaultTopedUp`. Pemilik: O-103/T-121, O-099/T-122.
- **Risiko tata kelola sampai akun per peran dipakai.** Sejak T-118/D-131 `platform_admin` adalah
  break-glass: peran sempit (`ops_admin`/`ledger_admin`/`cash_admin`/`product_maker`) dan lima
  pasangan SoD tersemai. Selama produksi masih memakai satu akun `platform_admin`, pemisahan tugas
  **belum** efektif — itu keputusan operasional pemilik (K-3), bukan cacat kode. Cara deteksi:
  `platform.user_role` (berapa akun memegang `platform_admin`), `platform.role_conflict`. Pemilik:
  O-102 (K-3/K-4).

## 5. Cara memakai dokumen ini

- Menemukan batas baru saat mengerjakan task → tambahkan baris (dampak, cara deteksi, pemilik), jangan
  simpan di kepala.
- Sebelum deploy → baca §1 dan §2. Yang paling langsung menyangkut deploy: freeze gate (fase 3),
  latihan deploy (T-013), prosedur migrasi dua tahap (`docs/runbooks/migrasi.md`), dan jendela drain
  10 detik (T-032).
- Batas "tidak ada rollback skema" **dihapus** oleh T-035 (D-040). Yang menggantikannya bukan klaim
  bebas risiko: rollback tetap butuh berkas pasangan yang sudah di-review, hanya berlaku untuk N
  migrasi terakhir, dan tidak tahu apa-apa soal data.

## 3. Batas sisa batch audit 24 Okt 2026 (T-133)

Ditambahkan saat menutup T-133. Setiap baris adalah temuan audit yang **tidak** dikerjakan di batch
itu, dengan alasan, cara mendeteksi, dan pemilik. Detail konteksnya ada di `docs/tasks/T-133.md` §2.

| Batas | Dampak nyata | Cara mendeteksi | Pemilik |
|---|---|---|---|
| `GET /audit` tanpa cursor (API-7) | Jejak lebih lama dari 200 baris terakhir hanya bisa ditinjau lewat SQL, bukan API | `GET /api/v1/audit?limit=200`; baris lama lewat kueri SQL langsung | Fase 9 (API lengkap); spec §13 |
| Upsert PII tanpa `ETag`/`If-Match` (API-8) | Dua editor back-office bisa saling menimpa tanpa peringatan | audit `party.update`/`*.update` menyimpan `before`/`after`; selisih terlihat di jejak, bukan dicegah | Fase 9; spec §13 |
| Fingerprint idempotensi memakai body apa adanya (API-9) | Retry dengan urutan key berbeda dijawab 409, bukan replay | header `Idempotent-Replayed` tidak muncul; 409 pada retry yang isinya sama tetapi urutannya diubah | T-085/D-098; klien aplikasi membangun body dengan urutan tetap |
| Penjaga expand-only hanya melihat kata pertama per statement (DB-6) | `UPDATE`/`DELETE` top-level dan DDL di dalam `DO $$ … $$` tidak terdeteksi `dbtools validate` | tinjauan PR migrasi + `./task dbtools validate`; migrasi berbahaya lolos tanpa alarm | Proses review migrasi (AGENTS §6) |
| Drift checksum terdeteksi di dalam loop apply; `--dry-run` melewati drift (DB-7) | Berkas yang isinya berubah ketahuan setelah berkas sebelumnya ter-commit, jadi DB bisa tertinggal setengah | galat "checksum berbeda" pada `dbtools migrate`; bandingkan `platform.schema_migration.checksum` dengan berkas | T-035/D-040 |
| Trigger imutabilitas tanpa `BEFORE TRUNCATE` pada beberapa tabel (DB-10) | `TRUNCATE` (superuser/psql) melewati trigger baris dan menghapus riwayat tanpa jejak | tidak ada jalur produksi yang mengeluarkan `TRUNCATE`; `itplatform` membuktikan trigger append-only pada `DELETE`/`TRUNCATE` `audit_log` | Peran DB (`kran_runtime` tanpa `TRUNCATE`, migrasi 0042) |
| Retensi/partisi `platform.audit_log`, `inbox`, `outbox` belum diputuskan (DB-12) | Tabel tumbuh tanpa batas; vacuum dan backup makin mahal tiap bulan | `pg_total_relation_size('platform.audit_log')`; belum ada job pemangkas | Fase 3/9 (kebijakan retensi, D-072 baru mengatur `journal`) |
| Orkestrasi use case masih di `apps/api/src` (~6,8k baris), `apps/` di-`catSkip` archcheck (ARC-3) | Batas Clean Architecture tidak ditegakkan untuk lapisan aplikasi; penulisan jurnal terduplikasi di empat tempat | `./task archcheck` hanya memeriksa `modules/`; tinjauan PR | Fase 3 (refactor bertahap, bukan perbaikan) |
| Belum ada `ctl outbox-redrive` (ARC-5) | Event `DEAD` hanya bisa dipulihkan lewat SQL manual; tidak ada jejak audit untuk pemulihan | `SELECT status, count(*) FROM platform.outbox GROUP BY 1` | Fase 9 (operabilitas); O-013 |
| Modul membaca tabel modul lain (`JOIN product.product`, ARC-6) | Batas modul dilanggar tanpa alarm: perubahan skema produk bisa mematahkan deposit | `archcheck` belum mendeteksi JOIN lintas skema; grep tinjauan | Fase 3 (port/`api.nim`) |
| `param_cache` hanya dipakai uji, komentar menunjuk `param_watcher.nim` yang tidak ada (ARC-7) | Kode mati yang membingungkan; tidak ada dampak runtime | `grep -rn param_cache modules apps` → hanya test | Fase 3 (hapus atau pakai) |
| Worker belum menangani SIGTERM/`pool.close()` (ARC-8) | Batch yang sedang diproses terpotong saat container berhenti; transaksi di-ROLLBACK dan outbox diulang (idempoten) | log worker berhenti di tengah batch; baris `platform.outbox` tetap `PENDING` lalu diproses ulang | Fase 9; O-025 |
| Pencarian party `ILIKE '%…%'` tanpa index trigram (ARC-9) | Pencarian pemilik rekening memindai seluruh `party.party`; makin lambat seiring data | `EXPLAIN ANALYZE` pada `GET /api/v1/parties?q=` | Fase 3 (data pilot masih kecil; `pg_trgm` sudah terpasang) |
| Advisory lock trigger audit menyerialkan transaksi teraudit (ARC-10) | Penulisan yang diaudit bergantian, bukan paralel; batas throughput per detik | `pg_locks` (advisory) saat beban; latensi endpoint yang menulis audit | Fase 9 (partisi/rantai per cabang) |
| Idempotensi kedaluwarsa (TTL) lalu dianggap baru (LED-3) | Operasi tanpa kunci alami (top-up vault, buka rekening) bisa tercatat dua kali bila klien mengulang setelah TTL lewat | dua baris isi sama setelah `platform.idempotency.ttl_hours`; klien mengirim ulang dengan kunci baru | Fase 3 (kunci alami per operasi) |
| Uji balapan tutup sesi tidak memaksa overlap (LED-4) | Balapan nyata pada penutupan sesi belum dibuktikan test; regresi bisa lolos | suite `itsession`/`itapi_teller_sessions` hijau, tetapi tanpa `pg_blocking_pids` | Fase 3 (mutu uji) |
| Lockout dibuktikan lewat repo + `/auth/password`, bukan N percobaan `POST /auth/login` (LED-5) | Jalur yang benar-benar dipakai penyerang tidak diuji sampai terkunci | `itapi_users` (429 beruntun) + audit `user.login.failure` | Fase 9 (mutu uji keamanan) |
| Properti uang memakai satu seed tetap, tanpa shrinking, batas `|v| ≤ 1e12` (LED-6) | Overflow penjumlahan `Money` tidak pernah diuji; kegagalan yang ditemukan tidak menyusut ke kasus minimum | `tprop_money` hijau; tidak ada kegagalan yang dilaporkan | Fase 3 (mutu uji) |
| Gate lebar 390px hanya di `/app/vault` (LED-7) | Layar lain (teller, ledger, cetak, buka rekening) belum dibuktikan bisa dipakai di ponsel | `vault.spec.ts` (390px) + `zoom-125.spec.ts`; sisanya tinjauan manual | Fase 3 (gate mobile penuh) |
| Backup Postgres tidak dienkripsi dan tersimpan di host yang sama (OPS-12) | dump dan DB bisa hilang bersama; isi dump terbaca siapa pun yang memegang berkas | drill restore (`docs/runbooks/restore-drill.md`); `ls -l` di direktori dump | Di luar repo (akses server); O-007 |
| CI tidak membangun image Docker API (OPS-13) | Regresi khusus image (Dockerfile, dependensi runtime) baru terlihat saat deploy produksi | health gate + pemeriksaan image `:local` di `deploy.log`; build lokal `podman build` | Fase 9 (CI image); T-131 |
| `HealthCmd` Podman tidak dipasang (OPS-15) | Proses yang menggantung tetapi masih menjawab TCP tidak terlihat oleh systemd (hanya oleh health gate deploy dan `/readyz` eksternal) | `systemctl --user status kran-api`; `/readyz` dari host; `Restart=always` untuk proses mati | Fase 9 (healthcheck butuh klien HTTP di image); T-133 |
| Action CI dipin ke tag mayor, bukan commit SHA (SEC-6) | Tag bisa dipindahkan pemilik action (supply chain); pin SHA menutup itu dengan biaya pembaruan manual | tinjauan `.github/workflows/*.yml`; pengumuman keamanan GitHub Actions | Pemilik repo (keputusan pemeliharaan) |
| "Hari ini" di `/app/ledger` memakai tanggal peramban; belum ada endpoint tanggal bisnis (UI-7) | Pemilihan periode awal bisa jatuh ke periode yang salah bila zona perangkat berbeda dari tanggal bisnis cabang | indikator "Tanggal bisnis" di shell masih `common_business_date_unknown`; periode terpilih di `/app/ledger` | Fase 3 (endpoint/kalender bisnis, spec §16.2) |
| `{#key locale}` me-remount subtree saat bahasa diganti (UI-8) | Input form yang sedang diisi hilang ketika pengguna berganti bahasa | ganti bahasa saat form terisi; fungsi Paraglide bukan store, jadi tanpa remount teks tidak berganti | Fase 3 (i18n reaktif) |
