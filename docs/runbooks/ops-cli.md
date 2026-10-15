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
| `ctl` | `kran-api --role=ctl daycloser-status` | **3** belum ada di Fase 0 (dipakai freeze gate deploy) |
| `ctl` | `kran-api --role=ctl bootstrap-admin --username=<nama>` | **0** admin dibuat, **3** sudah ada pemegang role admin, **2** tanpa `--username` |
| `ctl` | `kran-api --role=ctl help` | **0** |
| `worker` | `kran-api --role=worker` | **3** belum ada pekerjaan di Fase 0 |
| — | argumen salah / perintah tidak dikenal | **2** (bantuan ditulis ke stderr) |

Kode `2` = salah pakai atau konfigurasi (`KRAN_DATABASE_URL` kosong), `1` = perintah berjalan tapi
hasilnya buruk (mis. rantai audit tidak utuh), `3` = dikenali tapi belum diimplementasikan. Skrip ops
membedakan ketiganya, jadi jangan "merapikan" kode keluar tanpa memperbarui skrip.

## Yang dipakai skrip ops

- `ops/scripts/deploy-vps.sh`: `--role=migrate --check` (gate expand-only), lalu `--role=migrate --up`;
  freeze gate memanggil `--role=ctl daycloser-status` dan hanya bereaksi pada `RUNNING|CLOSING`
  (Fase 0: kode 3, tidak ada day-close → tidak memblokir deploy, tetapi **belum terbukti** karena
  skripnya belum pernah dijalankan di server — T-013).
- `ops/scripts/migrate.sh`: `--check` dan `--up` diteruskan apa adanya; `--contract`/`--down` ditolak
  skripnya (kode 3) karena biner belum mendukungnya — lihat `docs/OPEN_ITEMS.md` O-048.
- `ops/scripts/audit-consistency.sh` & `smoke.sh`: memakai jalur HTTP (`/healthz`, `/readyz`) dan
  `psql`; kontraknya ada di `docs/OPEN_ITEMS.md` O-019.

## Catatan

- Peran `ctl` sengaja **read-only**, dengan satu pengecualian: `bootstrap-admin`. Skrip otomatis
  memanggil perintah lain di peran ini tanpa pengawasan, jadi tidak boleh ada perintah lain yang
  menulis data (re-drive outbox dsb. menyusul sebagai perintah terpisah dengan `--yes`).
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
karakter mudah tertukar) dicetak **sekali** ke stdout. Yang tersimpan di DB hanya hash-nya; kalau
output-nya hilang sebelum dipakai, tidak ada cara memulihkannya — buat admin lain lewat alur
penugasan role biasa.

Sebelum kata sandinya diganti, akun itu hanya bisa memakai `/auth/session`, `/auth/password`, dan
`/auth/logout`. Rute ber-izin dijawab 403 `password_change_required` (juga di jalur realtime), dan
UI mengarahkan pengguna ke `/app/password` sampai selesai. Setelah ganti, sesi yang sedang dipakai
tetap hidup dan sesi lain milik pengguna itu dicabut.

Kode keluar: **0** berhasil, **3** ditolak karena sudah ada pemegang role admin (atau username sudah
dipakai) — perintah ini sekali-jalan dan tidak punya opsi paksa, **2** salah pakai (mis.
`--username` kosong), **1** gagal terhadap DB / kebijakan keamanan tidak sah.
