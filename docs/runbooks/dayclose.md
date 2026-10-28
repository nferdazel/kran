# Runbook — penutupan buku (day-close)

Kerangka `daycloser` (spec §11) menjalankan semua pekerjaan terjadwal institusi. **Tidak ada**
batch/cron lain di modul mana pun (AGENTS.md §1.7). Penutupan bisa dipicu tiga cara, semuanya lewat
jalur kode yang sama:

| Pemicu | Kapan dipakai |
|---|---|
| `ctl daycloser-run` | operator menyiapkan/mengulang penutupan; satu-satunya jalur untuk `--bootstrap` |
| `POST /api/v1/dayclose/run` (+ resume/pause/cancel) | tombol di layar `/app/dayclose` |
| `ctl daycloser-auto` oleh timer systemd | penutupan harian otomatis sesuai jam parameter |

Penjadwal memakai parameter `daycloser.auto.enabled` (default **mati**),
`daycloser.auto.run_at` (jam **lokal** `HH:MM`), dan `daycloser.auto.utc_offset_minutes`
(WIB = `420`). Unit + timer-nya ada di repo sebagai cermin (`ops/systemd/kran-dayclose.{service,timer}`);
memasangnya butuh akses server dan **tidak** dilakukan `deploy-vps.sh`.

Semua perintah dijalankan dari akar repo (atau `--root=<dir>`), dengan `KRAN_DATABASE_URL` yang
menunjuk DB yang benar. Di server, bungkus dengan container API:

```bash
podman exec kran-api /usr/local/bin/kran-api --role=ctl daycloser-status
```

## 0. Penjadwal otomatis (T-139b)

```bash
# Coba jalankan sekali secara manual (aman: tidak melakukan apa pun bila belum waktunya).
podman exec kran-api /usr/local/bin/kran-api --role=ctl daycloser-auto; echo $?

# Pasang di server (sekali):
scp ops/systemd/kran-dayclose.{service,timer} ~/.config/systemd/user/
systemctl --user daemon-reload && systemctl --user enable --now kran-dayclose.timer
systemctl --user list-timers kran-dayclose.timer
```

Kode keluar `daycloser-auto`: `0` = tidak ada yang perlu dikerjakan atau penutupan selesai,
`1` = penutupan berjalan tetapi berakhir `BLOCKED`/`FAILED`/`PAUSED` (periksa
`daycloser-status`, lalu resume/cancel), `2` = parameter tidak sah, `3` = ditolak keadaan
(tanggal buku belum ada, atau bukan hari kerja). Log: `~/…/logs/dayclose-auto.log` di server.

Bila jam tidak sesuai harapan: periksa `daycloser.auto.utc_offset_minutes`. Repo belum punya tabel
zona waktu, jadi selisih menit itu yang dipakai — institusi dengan DST harus menyesuaikannya
sendiri.

## 1. Keadaan yang mungkin

| `daycloser-status` | Arti | Tindakan |
|---|---|---|
| `0`, `tanggal buku: <tgl> OPEN`, `run aktif: tidak ada` | siap | boleh deploy; boleh mulai penutupan |
| `1`, `tanggal buku: <tgl> CLOSING` | penutupan belum selesai | **deploy ditahan**; `daycloser-resume` atau `daycloser-cancel` |
| `1`, run aktif `PAUSED`/`RUNNING` | proses berjalan atau berhenti di tengah | lihat run id, lanjutkan atau batalkan |
| `2` | DB/konfigurasi tidak terbaca | perbaiki koneksi; gate deploy juga menahan |

`daycloser-status` dipanggil gate deploy (`deploy-vps.sh`). Kode keluar **bukan nol** = deploy
ditahan. Jangan mengubah kode keluarnya tanpa memperbarui skrip.

## 2. Menutup hari pertama (bootstrap)

Hanya sekali, saat `platform.business_date` belum punya baris:

```bash
kran-api --role=ctl daycloser-run --business-date=2026-10-26 --bootstrap
```

`--bootstrap` menyatakan "ini tanggal buku pertama". Tanpanya perintah ditolak (kode 3). Setelah
hari itu ditutup, tanggal buku menjadi hari kerja berikutnya (`OPEN`) dan `--bootstrap` tidak
dipakai lagi.

## 3. Penutupan harian

```bash
kran-api --role=ctl daycloser-status                       # pastikan OPEN & tidak ada run aktif
kran-api --role=ctl daycloser-run --business-date=<tgl>    # tgl = tanggal buku berjalan
```

Alur yang dijalankan (spec §11.5): task `PRECHECK` → **freeze** (`CLOSING`) → task proses/laporan →
`POSTCHECK` → **seal** (run `COMPLETED`, tanggal `CLOSED`, rollover ke hari kerja berikutnya, event
`BusinessDateOpened`) — semuanya kecuali task dalam satu transaksi pada langkah seal.

Task proses yang berjalan: sapuan idempotensi dan **snapshot saldo harian**
(`ledger.daily_snapshot`, menulis + membuktikan cache saldo). Pada hari kerja terakhir bulan
(level EOM) ditambah **tutup periode GL** (`ledger.period_close`) — dijalankan pada fase pasca-tutup,
setelah snapshot dan gate, karena penutupan periode tidak bisa dibatalkan.

Periode yang ditutup adalah periode yang **memuat tanggal buku dan berakhir di bulan yang sama**.
Contoh: periode 1–31 Okt 2026 ditutup pada penutupan 30 Okt 2026 (hari kerja terakhir). Bila
institusi memakai periode tahunan, penutupan bulanan melaporkan `NOT_DUE` (tidak ada yang jatuh
tempo); bila tidak ada periode yang memuat tanggal itu sama sekali, run berhenti dengan `DAY-324`
dan periode harus dibuat lewat API lebih dulu.

Selama `CLOSING`, **semua perubahan lewat HTTP ditolak** `409` (`reason: business_date_closing`)
kecuali masuk/keluar dan ganti kata sandi. Itu disengaja: transaksi yang menyelinap di tengah
penutupan membuat gate pasca-tutup basi.

Bila institusi memang melayani 24 jam, `daycloser.txn_policy_during_close = ALLOW` harus ditetapkan
**sebelum** penutupan dimulai: alur maker-checker juga lewat HTTP, jadi ikut diblokir saat
`CLOSING`. Risiko race ditanggung institusi; belum diuji terhadap task penutup nyata (lihat
`docs/ACCEPTED-LIMITS.md`).

## 3b. Gate yang memblokir (run `BLOCKED`)

Run berhenti sebagai `BLOCKED` (bukan `FAILED`) bila **gate** gagal. Keluaran perintah menyebut
task dan kodenya; angka penyebabnya ada di `daycloser.task.metrics`:

```sql
SELECT t.task_id, t.state, t.error->>'code' AS code, t.metrics
  FROM daycloser.task t JOIN daycloser.run r USING (run_id)
 WHERE r.business_date = DATE '2026-10-28'
 ORDER BY t.task_id;
```

| Kode | Arti | Tindakan |
|---|---|---|
| `DAY-301` | sesi teller masih OPEN | tutup sesinya (kas dihitung) lewat aplikasi |
| `DAY-302` | sesi ditutup dengan kas tidak seimbang | selesaikan selisihnya lebih dulu |
| `DAY-303` | pengajuan top-up vault belum diputuskan | minta checker memutuskan |
| `DAY-304` | akun selisih bersaldo | posting jurnal koreksi **setelah** membatalkan run ini |
| `DAY-305` | trial balance tidak seimbang | jangan lanjut: selidiki jurnal, ini indikasi kerusakan data |
| `DAY-306/307` | saldo subledger tidak terbaca / rekening tanpa baris saldo | jalankan `ctl reconcile-deposits`, selidiki |
| `DAY-308` | total subledger ≠ GL | selidiki selisih; jangan "merapikan" dengan jurnal tanpa sebab |
| `DAY-309` | pasca-tutup dijalankan saat tanggal bukan `CLOSING` (atau waktu pembekuan tidak terbaca) | jangan lanjut: periksa `platform.business_date`; ini indikasi keadaan yang tidak konsisten |
| `DAY-310` | ada jurnal masuk setelah tanggal dibekukan | batalkan run, periksa jurnal itu, tutup ulang |
| `DAY-311` | akun pada parameter gate tidak dikenal / non-aktif | perbaiki parameter (`daycloser.precheck.suspense_accounts`, `daycloser.postcheck.subledger_gl_accounts`) lewat maker-checker |
| `DAY-312` | daftar akun pada parameter gate kosong | isi parameternya; daftar kosong akan mematikan gate tanpa memeriksa apa pun |
| `DAY-320` | snapshot saldo gagal ditulis (galat basis data) | lihat pesan galat; task dicoba ulang otomatis, run berhenti bila tetap gagal |
| `DAY-321` | snapshot saldo tidak sama dengan jurnal | jangan lanjut: bandingkan laporan `source=ledger` dengan `balance_snapshot` untuk tanggal itu. Rebuild-nya sudah di-rollback, jadi cache lama utuh. `metrics.accountDiff` menyebut akun yang berbeda |
| `DAY-323` | periode GL tidak terbaca | galat basis data; coba `daycloser-resume` setelah DB sehat |
| `DAY-325` | penutupan periode gagal (galat basis data) | periode tetap OPEN; periksa log, lalu `daycloser-resume` |
| `DAY-327` | periode berubah status di tengah penutupan | periksa `ledger.period`; bila sudah CLOSED oleh operator lain, resume akan melaporkan `alreadyClosed` |
| `DAY-322` | trial balance tidak seimbang saat snapshot | indikasi kerusakan data; jangan tutup buku |
| `DAY-324` | akhir bulan tetapi tidak ada periode GL yang berakhir hari ini | buat periode GL-nya lebih dulu, lalu jalankan penutupan lagi |
| `DAY-326` | sesi kas OPEN di rentang periode yang akan ditutup | batalkan run dulu (`daycloser-cancel`) — selama `CLOSING` semua tulisan HTTP ditolak, jadi sesi tidak bisa ditutup lewat aplikasi. Setelah tanggal kembali `OPEN`, tutup sesinya, lalu jalankan penutupan lagi |
| `DAY-328` | periode sebelumnya masih OPEN | tutup periode sebelumnya lebih dulu (berurutan); menutup bulan yang lebih baru membuat laporan bulan lama tidak punya dasar |
| `DAY-330` | daftar rekening akrual gagal dibaca | galat basis data; task dicoba ulang otomatis, run berhenti bila tetap gagal |
| `DAY-331` | versi produk rekening tidak punya atribut akrual yang sah (rate/basis/skala) | lengkapi binding versi produk lewat maker-checker, lalu `daycloser-resume`. Jangan mengakrualkan rekening tanpa perjanjian bunga yang jelas |
| `DAY-332` | tanggal rekening/tanggal buku tidak sah | data rusak; periksa `deposit.account.opened_on` dan `platform.business_date` |
| `DAY-333` | jurnal akrual tidak bisa dibuat | periksa rule `InterestAccrued` (seed `ledger/0065`) dan status periode tanggal buku |
| `DAY-334` | akrual ganda untuk rekening+tanggal | task seharusnya idempoten; selidiki tulisan kedua (advisory lock dilewati?) |
| `DAY-335` | bunga kumulatif menurun | pokok berkurang tanpa koreksi akrual; periksa mutasi rekening deposito itu |
| `DAY-336` | nilai bunga melampaui batas bilangan | pokok/rate produk tidak wajar; periksa binding |
| `DAY-337` | baris akrual gagal disimpan | galat basis data; task dicoba ulang otomatis |

Karena gate **pra**-tutup berjalan sebelum freeze, kegagalannya tidak membekukan tanggal: institusi
masih bisa melayani, tetapi tanggal itu tidak bisa ditutup dua kali (run `BLOCKED` harus di-resume
atau dibatalkan). Gate **pasca**-tutup berjalan saat tanggal sudah `CLOSING`, jadi semua tulisan
ditahan sampai run diselesaikan.

Saat `daycloser-resume`, **semua** gate dijalankan ulang (termasuk yang dulu lulus), karena keadaan
yang disertifikasi gate pra-tutup bisa berubah selama run berhenti. Jadi run yang di-resume bisa
kembali `BLOCKED` dengan kode yang berbeda — itu perilaku yang benar, bukan kegagalan resume.

Jurnal yang dibuat **setelah** freeze untuk tanggal itu akan ditolak gate `DAY-310` saat resume.
Jalur yang benar: batalkan run (`daycloser-cancel`), perbaiki buku, lalu jalankan penutupan lagi
untuk tanggal yang sama.

## 4. Gagal atau berhenti di tengah

`daycloser-run` keluar **1** bila run berakhir `FAILED`/`BLOCKED`. Tanggal buku **tetap
`CLOSING`** — itu yang menahan deploy dan transaksi sampai masalahnya diselesaikan.

1. Lihat penyebabnya: keluaran perintah menyebut task dan kode galat; `daycloser-status`
   menampilkan run terakhir (termasuk segel bila selesai).
2. Perbaiki penyebabnya (mis. parameter yang salah, hari libur yang belum terdaftar).
3. Lanjutkan **tanpa mengulang chunk yang sudah sukses**:

   ```bash
   kran-api --role=ctl daycloser-resume --run=<uuid>
   ```

4. Bila penutupan itu memang tidak bisa diselesaikan sekarang, batalkan:

   ```bash
   kran-api --role=ctl daycloser-cancel --run=<uuid>
   ```

   Bila tidak ada proses yang memegang lock, pembatalan berlaku **saat itu juga**: sisa task
   `CANCELED`, run `CANCELED`, dan tanggal buku dibuka kembali (`CLOSING → OPEN`). Bila ada proses
   hidup, permintaan dibaca di batas chunk berikutnya.

`CLOSED` tidak pernah dibuka kembali (spec §11.7). Koreksi setelah tutup = jurnal pembalik di hari
berjalan, bukan membuka ulang tanggal.

Run yang sudah `CANCELED` **boleh diulang** untuk tanggal yang sama:

```bash
kran-api --role=ctl daycloser-run --business-date=<tgl>
```

Itu satu-satunya cara memajukan buku setelah pembatalan. Run baru bergantung pada idempotensi task
(`imPerBusinessDate`), jadi chunk yang sudah sukses pada run lama tidak menggandakan posting.

Bila `daycloser-cancel` menjawab "tanggal buku … dibuka kembali (pemulihan pembatalan)", itu jalur
pemulihan untuk keadaan lama `CANCELED` + `CLOSING`; jalankan sekali, lalu periksa
`daycloser-status` (harus 0).

## 5. Run yang macet (`RUNNING` lama)

1. Cek apakah prosesnya masih ada (container/`ps`). Bila proses mati tetapi state `RUNNING`,
   `daycloser-resume` mengembalikan task/chunk `RUNNING` ke `PENDING` lalu melanjutkan.
2. Bila proses masih hidup tetapi menggantung, `daycloser-cancel` menulis `control = CANCEL` dan
   orkestrator berhenti di batas chunk. Tidak ada timeout per task (batas tercatat, T-140).

## 6. Cek bukti

```sql
SELECT run_id, business_date, state, summary_hash, started_at, finished_at
  FROM daycloser.run ORDER BY business_date DESC LIMIT 5;

SELECT action, business_date, resource_id FROM platform.audit_log
 WHERE action LIKE 'daycloser.%' ORDER BY seq DESC LIMIT 20;

SELECT event_type, payload FROM platform.outbox
 WHERE event_type = 'BusinessDateOpened' ORDER BY seq DESC LIMIT 5;
```

`summary_hash` dihitung dari snapshot parameter + state/attempt task dan chunk; run `COMPLETED`
tanpa segel tidak mungkin (satu transaksi).

## 7. Deploy

Deploy saat `CLOSING` akan ditolak gate (`exit 0` di webhook, log `FREEZE`). Tunggu penutupan
selesai, atau batalkan run lebih dulu. Jangan memaksa dengan mengubah state DB secara manual — itu
membuat segel dan audit tidak lagi menjelaskan keadaan sebenarnya.
