# Runbook — penutupan buku (day-close)

Kerangka `daycloser` (spec §11) menjalankan semua pekerjaan terjadwal institusi. **Tidak ada**
batch/cron lain di modul mana pun (AGENTS.md §1.7). Sampai T-139 mendarat, penutupan dipicu
operator lewat `ctl`; tidak ada penjadwal otomatis.

Semua perintah dijalankan dari akar repo (atau `--root=<dir>`), dengan `KRAN_DATABASE_URL` yang
menunjuk DB yang benar. Di server, bungkus dengan container API:

```bash
podman exec kran-api /usr/local/bin/kran-api --role=ctl daycloser-status
```

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

Selama `CLOSING`, **semua perubahan lewat HTTP ditolak** `409` (`reason: business_date_closing`)
kecuali masuk/keluar dan ganti kata sandi. Itu disengaja: transaksi yang menyelinap di tengah
penutupan membuat gate pasca-tutup basi.

Bila institusi memang melayani 24 jam, `daycloser.txn_policy_during_close = ALLOW` harus ditetapkan
**sebelum** penutupan dimulai: alur maker-checker juga lewat HTTP, jadi ikut diblokir saat
`CLOSING`. Risiko race ditanggung institusi; belum diuji terhadap task penutup nyata (lihat
`docs/ACCEPTED-LIMITS.md`).

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
