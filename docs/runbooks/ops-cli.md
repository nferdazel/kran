# Runbook — kontrak CLI `cbs-api` (peran proses)

Satu biner, empat peran (spec §21.4, §26.1 #5). Semua perintah di bawah dijalankan dari **akar
repo** (atau dengan `--root=<dir>` yang menunjuk ke sana), karena migrasi dibaca relatif terhadap
`--root`.

| Peran | Perintah | Keluar |
|---|---|---|
| `api` | `cbs-api --role=api [--port=8080] [--address=127.0.0.1] [--version=<str>]` | berjalan sampai SIGINT/SIGTERM → **0** (D-031) |
| `migrate` | `cbs-api --role=migrate` atau `--role=migrate --up` | **0** bila selesai (idempoten) |
| `migrate` | `cbs-api --role=migrate --check` | **0** bersih, **1** ada migrasi tertunda atau isi migrasi berubah (drift) |
| `ctl` | `cbs-api --role=ctl verify-audit` | **0** rantai audit utuh, **1** ada entri tidak utuh |
| `ctl` | `cbs-api --role=ctl outbox-status` | **0** (hanya mencetak jumlah per status) |
| `ctl` | `cbs-api --role=ctl daycloser-status` | **3** belum ada di Fase 0 (dipakai freeze gate deploy) |
| `ctl` | `cbs-api --role=ctl help` | **0** |
| `worker` | `cbs-api --role=worker` | **3** belum ada pekerjaan di Fase 0 |
| — | argumen salah / perintah tidak dikenal | **2** (bantuan ditulis ke stderr) |

Kode `2` = salah pakai atau konfigurasi (`CBS_DATABASE_URL` kosong), `1` = perintah berjalan tapi
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

- Peran `ctl` sengaja **read-only**: skrip otomatis memanggilnya tanpa pengawasan, jadi tidak boleh
  ada perintah yang menulis data (re-drive outbox dsb. menyusul sebagai perintah terpisah dengan
  `--yes`).
- `--role=migrate` memakai implementasi yang sama dengan `./task dbtools migrate`/`validate`
  (`tools/dbtools/lib.nim`), supaya tidak ada dua jalur migrasi yang bisa berbeda hasil.

## Catatan hasil nyata di DB dev

`ctl verify-audit` pada DB dev bisa mengembalikan **1** meski kodenya benar: test
`modules/platform/tests/itplatform.nim` sengaja merusak rantai audit (mematikan trigger pemeriksa,
mengubah satu baris, lalu menyalakannya lagi) untuk membuktikan deteksinya. Jadi kode 1 di DB dev
bukan sinyal kerusakan nyata — karena itu test peran di `apps/api/tests/itapi_roles.nim` membandingkan
kode keluar dengan hasil `verifyChain` pada DB yang sedang dipakai, bukan menuntut selalu 0.
