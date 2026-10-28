# Runbook — kontrak CLI `kran-api` (peran proses)

Satu biner, empat peran (spec §21.4, §26.1 #5). Semua perintah di bawah dijalankan dari **akar
repo** (atau dengan `--root=<dir>` yang menunjuk ke sana), karena migrasi dibaca relatif terhadap
`--root`.

| Peran | Perintah | Keluar |
|---|---|---|
| `api` | `kran-api --role=api [--port=8080] [--address=127.0.0.1] [--version=<str>]` | berjalan sampai SIGINT/SIGTERM → **0** (D-031) |
| `migrate` | `kran-api --role=migrate` atau `--role=migrate --up` | **0** bila selesai (idempoten) |
| `migrate` | `kran-api --role=migrate --check` | **0** bersih, **1** ada migrasi tertunda atau isi migrasi berubah (drift) |
| `ctl` | `kran-api --role=ctl verify-audit` | **0** rantai audit utuh, **1** ada entri tidak utuh |
| `ctl` | `kran-api --role=ctl outbox-status` | **0** (hanya mencetak jumlah per status) |
| `ctl` | `kran-api --role=ctl daycloser-status` | **0** tidak ada penutupan berjalan, **1** ada run aktif atau business date `CLOSING` (gate deploy menahan), **2** DB/konfigurasi tidak terbaca (juga menahan) |
| `ctl` | `kran-api --role=ctl daycloser-run --business-date=<YYYY-MM-DD>` | **0** run `COMPLETED`, **1** run `FAILED`/`BLOCKED`, **3** ditolak (bukan hari kerja, run lain berjalan), **2** argumen/parameter salah |
| `ctl` | `kran-api --role=ctl daycloser-resume --run=<uuid>` | **0** run selesai `COMPLETED`, **1** masih gagal, **3** run sudah berakhir atau lock dipegang proses lain, **2** argumen kurang |
| `ctl` | `kran-api --role=ctl daycloser-pause --run=<uuid>` | **0** permintaan dicatat (dibaca di batas chunk), **3** run sudah berakhir, **2** tanpa `--run` |
| `ctl` | `kran-api --role=ctl daycloser-cancel --run=<uuid>` | **0** permintaan dicatat, **3** run sudah berakhir, **2** tanpa `--run` |
| `ctl` | `kran-api --role=ctl bootstrap-admin --username=<nama>` | **0** admin dibuat, **3** sudah ada pemegang role admin, **2** tanpa `--username` |
| `ctl` | `kran-api --role=ctl reset-password --username=<nama>` | **0** kata sandi baru dicetak sekali, **1** gagal menulis/acak, **2** tanpa `--username`, **3** pengguna tidak ada |
| `ctl` | `kran-api --role=ctl audit-anchor [--out=<berkas>]` | **0** baris anchor dicetak (dan ditambahkan ke berkas), **1** gagal menulis, **2** tanpa DB |
| `ctl` | `kran-api --role=ctl reconcile-deposits [--branch=<uuid>]` | **0** semua cache saldo cocok, **1** ada selisih (temuan), **2** argumen salah |
| `ctl` | `kran-api --role=ctl create-user --username=<nama> --user-role=<peran> [--branch=<uuid>] [--full-name=<nama>]` | **0** akun dibuat (kata sandi dicetak sekali), **3** ditolak (username/role/scope), **2** argumen kurang, **1** gagal menulis/acak |
| `ctl` | `kran-api --role=ctl assign-role --username=<nama> --user-role=<peran> [--branch=<uuid>]` | **0** role diberikan, **3** ditolak/tidak ditemukan (role/scope/SoD), **2** argumen kurang, **1** gagal menulis |
| `ctl` | `kran-api --role=ctl revoke-role --username=<nama> --user-role=<peran> [--branch=<uuid>]` | **0** role dicabut, **3** ditolak/tidak ditemukan (termasuk pengelola terakhir), **2** argumen kurang, **1** gagal menulis |
| `ctl` | `kran-api --role=ctl disable-user --username=<nama>` | **0** akun `INACTIVE` + sesi dicabut, **3** tidak ada / pengelola terakhir, **2** tanpa `--username`, **1** gagal menulis |
| `ctl` | `kran-api --role=ctl enable-user --username=<nama>` | **0** `INACTIVE`→`ACTIVE`, **3** tidak ada / bukan `INACTIVE`, **2** tanpa `--username`, **1** gagal menulis |
| `ctl` | `kran-api --role=ctl unlock-user --username=<nama>` | **0** `LOCKED`→`ACTIVE`, **3** tidak ada / bukan `LOCKED`, **2** tanpa `--username`, **1** gagal menulis |
| `ctl` | `kran-api --role=ctl create-branch --branch-code=<3 digit> --branch-name=<nama>` | **0** cabang didaftarkan, **3** kode tidak sah/sudah dipakai, **2** argumen kurang |
| `ctl` | `kran-api --role=ctl post-opening-balance --username=<nama> --branch=<uuid> --amount=<nominal> --business-date=<YYYY-MM-DD>` | **0** jurnal saldo awal diposting (idempoten per cabang), **3** pengguna/cabang/periode/nominal ditolak, **2** argumen kurang/salah, **1** jurnal ditolak DB |
| `ctl` | `kran-api --role=ctl help` | **0** |
| `worker` | `kran-api --role=worker` | berjalan (loop konsumen outbox) sampai dihentikan; **2** parameter/DB belum siap (tidak di-restart), **1** DB transien |
| — | argumen salah / perintah tidak dikenal | **2** (bantuan ditulis ke stderr) |

Kode `2` = salah pakai atau konfigurasi (`KRAN_DATABASE_URL` kosong), `1` = perintah berjalan tapi
hasilnya buruk (mis. rantai audit tidak utuh, run day-close gagal), `3` = dikenali tetapi **sengaja
ditolak pada keadaan itu** (mis. bukan hari kerja, run lain masih berjalan, `--contract` saat expand
masih tertunda, `--down` tanpa berkas pasangan). Skrip ops membedakan ketiganya, jadi jangan
"merapikan" kode keluar tanpa memperbarui skrip.

## Yang dipakai skrip ops

- `ops/scripts/deploy-vps.sh`: `--role=migrate --check` (gate expand-only), lalu `--role=migrate --up`;
  freeze gate memanggil `--role=ctl daycloser-status` dan bereaksi pada **kode keluar bukan 0**
  (T-134/D-148). Teks status tidak lagi dipakai untuk keputusan; keluaran tetap memuat `RUNNING`/
  `CLOSING` supaya skrip lama yang masih terpasang juga benar. Biner yang belum mengenal perintah
  keluar 3 → menahan deploy (fail-closed).
- `ops/scripts/migrate.sh`: `--check`/`--up` diteruskan apa adanya; `--contract` dan `--down N` juga
  diteruskan, tetapi wajib `--yes` (dan `--down` wajib N) — penolakan argumen terjadi di skrip (kode 2),
  penolakan keadaan terjadi di biner (kode 3). Prosedurnya: `docs/runbooks/migrasi.md` (D-040).
- `ops/scripts/smoke.sh`: memakai jalur HTTP (`/healthz`, `/readyz`, lalu versi vs `.deployed_rev`);
  `ops/scripts/audit-consistency.sh`: membandingkan md5 `ops/scripts/*.sh` di repo dengan salinan di
  server. Kontrak endpointnya ada di `docs/OPEN_ITEMS.md` O-019.

## Catatan

- Peran `ctl` mayoritas **read-only**; perintah yang menulis data: `bootstrap-admin`,
  `reset-password`, `create-user`, `assign-role`, `revoke-role`, `disable-user`, `enable-user`,
  `unlock-user`, `create-branch`, `post-opening-balance`, dan `daycloser-run|resume|pause|cancel`
  (`audit-anchor` hanya menambah berkas).
  Semuanya menulis audit; tidak ada yang memakai `--yes` karena bukan rollback skema — pemulihan
  akses/lifecycle harus bisa dijalankan saat insiden. Skrip otomatis memanggil perintah read-only
  di peran ini tanpa pengawasan, jadi jangan menambah perintah tulis di luar daftar itu (re-drive
  outbox dsb. menyusul dengan `--yes`).
- `--role=migrate` memakai implementasi yang sama dengan `./task dbtools migrate`/`validate`
  (`tools/dbtools/lib.nim`), supaya tidak ada dua jalur migrasi yang bisa berbeda hasil.

## Catatan hasil nyata di DB dev

`ctl verify-audit` pada DB dev bisa mengembalikan **1** meski kodenya benar: test
`modules/platform/tests/itplatform.nim` sengaja merusak rantai audit (mematikan trigger pemeriksa,
mengubah satu baris, lalu menyalakannya lagi) untuk membuktikan deteksinya. Jadi kode 1 di DB dev
bukan sinyal kerusakan nyata — karena itu test peran di `apps/api/tests/itapi_roles.nim` membandingkan
kode keluar dengan hasil `verifyChain` pada DB yang sedang dipakai, bukan menuntut selalu 0.


## Bootstrap admin pertama (`ctl bootstrap-admin`, T-027)

```
kran-api --role=ctl bootstrap-admin --username=admin.pertama
```

Yang terjadi: pengguna dibuat dengan `must_change_password = true` dan role `platform_admin`
(katalog izin & role sistem ada di migrasi `0008_platform_rbac_catalogue.sql`, jadi role itu memang
punya seluruh izin yang dikenal), lalu kata sandi awal acak (CSPRNG; panjangnya `password_min_length` + margin, alfabet tanpa
karakter mudah tertukar) dicetak **sekali** ke stdout. Yang tersimpan di DB hanya hash-nya; kalau output-nya hilang sebelum
dipakai, jalurnya `reset-password --username=<nama>` di bawah (bukan UPDATE SQL manual).

Sebelum kata sandinya diganti, akun itu hanya bisa memakai `/auth/session`, `/auth/password`, dan
`/auth/logout`. Rute ber-izin dijawab 403 `password_change_required` (juga di jalur realtime), dan
UI mengarahkan pengguna ke `/app/password` sampai selesai. Setelah ganti, sesi yang sedang dipakai
tetap hidup dan sesi lain milik pengguna itu dicabut.

Kode keluar: **0** berhasil, **3** ditolak karena sudah ada pemegang role admin (atau username sudah
dipakai) — perintah ini sekali-jalan dan tidak punya opsi paksa, **2** salah pakai (mis.
`--username` kosong), **1** gagal terhadap DB / kebijakan keamanan tidak sah.

## Reset kata sandi (lupa kata sandi awal) — D-100

```bash
cd /srv/qouver/apps/kran/monorepo
KRAN_DATABASE_URL="$(grep '^KRAN_DATABASE_URL=' /srv/qouver/apps/kran/env/kran-prod.env | cut -d= -f2-)"
KRAN_DATABASE_URL="${KRAN_DATABASE_URL//@qouver-postgres:/@127.0.0.1:}"
KRAN_DATABASE_URL="$KRAN_DATABASE_URL" LD_LIBRARY_PATH=/srv/qouver/apps/kran/lib \
  /srv/qouver/apps/kran/bin/kran-api --role=ctl reset-password --username=admin
```

Yang terjadi: kata sandi acak dicetak **sekali**; hash memakai iterasi parameter produksi;
`must_change_password=true`; akun `LOCKED` dikembalikan ke `ACTIVE` (status `INACTIVE`/`SUSPENDED`
**tidak** diaktifkan); hash lama masuk `user_password_history` sehingga tidak bisa dipakai ulang;
semua sesi dicabut; audit `user.password_reset` tercatat dalam transaksi yang sama. Login berikutnya
dipaksa ganti kata sandi. Jangan mengubah `platform.app_user.password_hash` lewat SQL — itu
melewati audit dan pencabutan sesi.

## Anchor rantai audit (O-009, D-108)

```bash
podman run --rm --network qouver \
  --env-file /srv/qouver/apps/kran/env/kran-prod.env \
  -v /srv/qouver/audit-anchor:/anchor:Z \
  localhost/kran-api:local --role=ctl audit-anchor --out=/anchor/audit-anchor.log
```

Satu baris = `waktu-UTC seq=<n> hash=<hash>`, ditambahkan (append) ke berkas. Simpan berkas itu di
**luar** DB/backup DB (mis. ikut backup harian ke host lain). Verifikasi: `ctl verify-audit` harus
menyatakan rantai utuh, dan `seq`/`hash` baris anchor terakhir harus sama dengan baris
`platform.audit_log` pada `seq` itu. Jadwalkan harian (systemd timer/cron) — penjadwalan adalah
tindakan host, bukan dari repo.

## Alert otomatis (O-092)

`kran-alert.timer` (user systemd, tiap 2 menit) menjalankan `ops/scripts/kran-alert.sh`:

- `/readyz` non-200 → pesan berisi nama check yang gagal + detail;
- `platform.outbox` status `DEAD` > 0 → pesan berisi jumlahnya;
- pengiriman lewat `tg-notify.sh` (kanal Telegram yang sama dengan backup), hanya saat status
  berubah dan diulang tiap 6 jam selama masih bermasalah;
- status terakhir di `~/.local/state/kran-alert/last`, log di `~/kran-alert.log`;
- **tidak memprobe saat deploy berjalan** (lock `/srv/qouver/apps/kran/.deploy.lock` dipegang):
  selagi repo disinkronkan sebelum `migrate --up`, API lama bisa sesaat melaporkan
  "migrasi expand tertunda"; itu normal dan tidak dikirim sebagai alert. Status tersimpan tidak
  diubah, jadi deploy yang gagal tetap memicu alert pada probe berikutnya;
- skrip yang dijalankan timer ada di `/srv/qouver/scripts/kran-alert.sh` (salinan manual, bukan
  hasil deploy). Setelah mengubah `ops/scripts/kran-alert.sh` di repo, salin ulang ke path itu;
- uji tanpa kirim: `/srv/qouver/scripts/kran-alert.sh --dry-run`.
