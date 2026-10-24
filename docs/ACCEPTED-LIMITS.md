# Batas yang diterima — Fase 0

Dokumen ini adalah **register keputusan**, bukan daftar keinginan. Aturannya satu: setiap batas harus
punya (a) dampak nyata, (b) cara mendeteksinya, dan (c) pemilik — fase atau task yang menanganinya.
Kalau salah satu tidak ada, itu bukan batas yang diterima melainkan pekerjaan yang terlupa.

Alasan dokumen ini ada: "Fase 0 tanpa cela" bukan sesuatu yang bisa dibuktikan siapa pun. Yang bisa
dibuktikan adalah **tidak ada celah yang diketahui pada jalur yang diperiksa**, dan setiap hal yang
belum ditangani tercatat beserta cara melihatnya. Register ini adalah bagian kedua dari kalimat itu.

## 1. Batas yang memang milik fase lain (tidak dipaksakan masuk Fase 0)

| Batas | Dampak nyata | Cara mendeteksi | Pemilik |
|---|---|---|---|
| Metrics/observability belum ada (Prometheus-style: latensi, error rate, pool PG, antrean outbox, durasi task day-close) | Tidak ada pengukuran berkelanjutan; operator hanya punya log terstruktur | `/healthz`, `/readyz`, log JSON, dan kueri SQL manual | Fase 9 (spec §22, §23) |
| Freeze katalog produk sebelum T-086 | Perubahan produk produksi dibekukan; pilot satu operator akan terblokir `checker <> maker` setelah maker-checker aktif | `ProductPublished` tidak terbit saat submit; approve tanpa operator kedua → 409 `self_approval` | T-086, D-099, D-119 |
| Freeze gate day-close | Deploy tidak bisa diblokir karena EOD berjalan; `ctl daycloser-status` selalu "belum ada" | jalankan `ctl daycloser-status` — nilainya selalu 3 sampai `daycloser` ada | Fase 3 (framework `daycloser`); O-013 |
| Uji restore & latihan DR | Tidak ada bukti backup bisa dipulihkan | belum pernah dijalankan | Di luar repo (akses server); O-002, O-007 |
| Target performa (spec §1.4: EOD 100k rekening + 50k pinjaman < 30 menit) | Belum ada bukti skala; angka target belum pernah diuji | belum ada benchmark | Fase 3 (day-close) + Fase 9 |
| Multi-instance / HA | Satu proses = satu titik gagal | arsitektur: satu biner, satu pool, satu pump | Fase 9 (cutover §23) |
| MFA & matriks pemisahan tugas (SoD) | Kontrol akses = kata sandi + RBAC + audit; belum ada faktor kedua | periksa katalog izin & pengaturan akun | Item O-015, O-016 |

## 2. Batas teknis yang diterima setelah batch "Fase 0 tahan banting"

| Batas | Dampak nyata | Cara mendeteksi | Pemilik |
|---|---|---|---|
| Rollback layanan tidak mengembalikan skema; contract produk `0004` tetap terpasang | Binary lama + skema pasca-contract menyimpan versi sebagai DRAFT (seal lama sudah dilepas), jadi versi dari jendela itu perlu approve manual setelah pulih | `SELECT status, sealed FROM product.product_version` untuk versi yang dibuat selama jendela rollback | T-086, T-090, D-119, D-040 |
| Migrasi contract/rollback baru terbukti di DB dev, belum di server | Rollback skema belum pernah dilatih pada data nyata; pasangan `.down.sql` belum ada untuk migrasi nyata | jalankan latihan deploy (T-013) sebelum mengandalkannya | T-035, D-040 |
| Job CI GitHub belum lengkap (`db-tests`/`traceability`) | CI GitHub tidak menjalankan uji integrasi DB; gate yang sebenarnya adalah `./task ci` lokal (butuh DB dev) | lihat `docs/ci-jobs.md` | O-027 |
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
| Percobaan kata sandi lama di `/auth/password` belum dibatasi/diaudit | Tidak ada perlindungan brute-force pada endpoint itu | belum ada penghitung percobaan di sana | O-050 |
| PB lintas cabang diatribusikan hanya ke cabang sumber (audit, jurnal, event) | Kedua baris D/K 201 ber-`branch_id` sumber, jadi GL 201 cabang tujuan tidak mencerminkan kredit sementara subledger rekening naik: neraca cabang vs subledger menyimpang sebesar nominal PB | query `deposit.transfer` per `branch_id` kedua akun dibandingkan `journal_line` 201 per cabang; belum ada laporan GL per cabang | T-101/Fase 3 (D-124) |
| Cache saldo `deposit.account_balance` bisa menyimpang dari baris mutasi (kas + PB) | Saldo teller dari cache; restore parsial atau bug tulis membuat saldo tidak cocok dengan baris sumber. Perbandingan terhadap GL per rekening **tidak mungkin** selama liabilitas dipool di akun `201` (PB net-nol) | **DITUTUP SEBAGIAN (T-101, 24 Okt 2026)**: `ctl reconcile-deposits [--branch]` membandingkan cache dengan `deposit.transaction` + `deposit.transfer` (exit 1 bila ada selisih, termasuk cache hilang). Belum dijadwalkan otomatis, dan jurnal simpanan yang dibalik tidak memutar baris simpanan (T-123) | Fase 3 (day-close), T-123 |
| Jurnal pemindahbukuan (PB, `DepositTransferred`) **net-nol di GL**: kedua sisinya akun `201` yang sama | Buku besar tidak membedakan pemilik rekening; `journal_line` saja tidak cukup merekonstruksi saldo per rekening dari PB, dan GL per pemilik anggota belum ada | perpindahan per rekening ada di `deposit.transfer` (sumber & tujuan); bandingkan saldo `deposit.account`/`account_balance` dengan `deposit.transfer` + jurnal 201 | T-101/Fase 3; `modules/deposit/MODULE.md` |
| Hanya pengenal cabang berbentuk **uuid** yang bisa diatribusi ke `platform.audit_log.branch_id` | Entri audit untuk cabang ber-id teks (id warisan/seeder) tetap `branch_id` NULL, jadi pemisahan audit per cabang tidak berlaku untuknya; pengenalnya tetap utuh di `resource_id`/payload | `SELECT branch_id FROM platform.audit_log WHERE action = 'param.submit' AND resource_id = ...` → NULL; diuji eksplisit di `itapi_auth` (suite scoping cabang, test pengenal non-uuid) | O-017; T-058, D-062 |
| Topik realtime `param.changed` hanya dibuka untuk grant **tanpa** batas cabang | Pengguna yang izinnya khusus cabang tidak menerima peristiwa parameter sama sekali (fail-closed, bukan bocor); membukanya tanpa penyaringan justru mengirim peristiwa semua cabang | langganan topik gagal pada klien ber-grant khusus cabang; `topicsAllowedFor` memakai `authorized` tingkat institusi | O-070; T-058, D-062 |
| Penerus yang ditolak **setelah** nilai ber-`effective_to` disetujui meninggalkan celah (tidak ada nilai berlaku setelah tanggal itu) | Aplikasi gagal-cepat saat startup (`missingActiveKeys`); pemulihannya dengan mengajukan + menyetujui penerus baru | pemeriksaan ulang saat persetujuan menutup kasus penerus hilang **sebelum** persetujuan (`itapi_auth`: 409); celah yang lolos tetap terdeteksi startup check O-057 | D-056; O-043/O-065 |
| Regulasi spec §4 bertanda `V?`/`V!` belum terverifikasi | Pasal/angka bisa berubah; yang bergantung padanya belum final | penanda `NEEDS-COMPLIANCE-REVIEW` di kode/seed/docs | O-001 |
| Belum ada kontrak-fuzzing (`schemathesis`) dan visual regression | Cakupan uji kontrak/visual lebih sempit daripada rencana spec | lihat daftar uji; parity kontrak diuji lewat `tcontract`/`itapi` | O-026, O-022 |
| Lint statis generik (ESLint) belum ada — bagian a11y **sudah tertutup** | Aturan `svelte/*` non-a11y dan `typescript-eslint` belum menegakkan apa pun; diagnostik a11y kompilator kini memblokir lewat `svelte-check --fail-on-warnings` | diputuskan 17 Okt 2026 (D-053) untuk dikerjakan bersama T-012 | O-023, T-057 |
| Tag image lama yang masih direferensikan container berhenti tidak bisa dihapus `podman rmi` | Tag itu tetap ada sampai container berhenti dibersihkan; pertumbuhan disk tertahan, bukan nol | baris `WARN: gagal menghapus …` di `deploy.log`; `podman ps -a` | T-069 |
| `KRAN_KEK_FILE` belum di-mount ke container | Fitur yang membutuhkan KEK (field crypto/MFA) tidak bisa aktif di produksi; dengan env kosong fitur itu inert, bukan rusak diam-diam | `podman inspect kran-api` tidak memuat mount KEK; startup check parameter MFA | D-066; O-071 |
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

## 4. Bukti yang ada hari ini

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
Ia bukan klaim pekerjaan selesai: celah UI-nya dicatat sebagai task backlog T-115…T-117, dan keputusan
tata kelolanya menunggu pemilik (O-102).

- **Tidak ada UI top-up vault (API-nya ada).** Setup
  operator berjalan lewat CLI/API saja: akun dan peran lewat `kran-api --role=ctl bootstrap-admin` /
  `create-user` (satu role) / `reset-password`; pekerjaan bisnis lewat `curl` ke endpoint yang sudah ada
  (`POST /api/v1/deposit/accounts`, `POST /api/v1/ledger/periods`, `POST /api/v1/ledger/coa`,
  `POST /api/v1/ledger/journals/{journalId}/reversal`, `POST /api/v1/teller/vault/topups`) atau SQL
  runbook. Dampak: operasi harian tidak bisa dilakukan operator non-teknis. Cara deteksi: tidak ada rute
  UI di `apps/web` untuk alur itu; daftar permukaan yang ada di `apps/api/src/routes.nim`. Pemilik:
  O-103, T-115…T-117.
- **Top-up vault: API maker-checker, belum ada UI.** `POST /teller/vault/topups` (izin
  `teller.vault.submit`) hanya membuat pengajuan; `.../{requestId}/approve` (izin
  `teller.vault.approve`) oleh akun lain menulis saldo + jurnal `D <teller.vault.cash_account> / K
  <akun sumber>`. Tanpa UI, operator memakai `curl`. Dampak: langkah ganda mudah dilewati/dilupakan
  bila dijalankan manual. Plafon per pengajuan sudah ada (D-133). Cara deteksi: `teller.vault_topup_request`
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
