# Runbook — setup deploy (deploy key + webhook)

Status: **deploy belum pernah dijalankan**; deploy key + hook webhook **sudah terpasang**
(15 Okt 2026, buktinya di `docs/tasks/T-040.md`). Bagian yang masih rencana: latihan deploy (T-013). Langkah yang menyentuh server harus diverifikasi di server; yang
tidak bisa dibuktikan di sini ditulis begitu, bukan diasumsikan berhasil. Spec: §21.4 (alur deploy),
§21.5 (unit & direktori), §21.7 (webhook).

## Urutan yang benar, dan alasannya

1. Rename identifier teknis (T-039) — **selesai** (D-039).
2. Latihan `deploy-vps.sh` manual di server (T-013) — **belum**.
3. Deploy key + hook webhook (dokumen ini) — langkah terakhir.

Alasannya bukan formalitas: webhook inilah yang membuat `push` ke `main` menjadi **deploy ke
produksi**. Bila dipasang sebelum ada latihan, push pertama Anda adalah uji coba langsung ke produksi —
sementara `cbs-core` masih melayani di `127.0.0.1:8095`, port yang justru mau diambil alih unit kita
(§21.5). Selama belum dilatih, jangan push ke `main`.

## A. Deploy key (read-only) untuk VPS

Skrip deploy hanya `fetch`; tidak ada yang mendorong dari server. Karena itu kunci **read-only** cukup,
dan itu memang bawaan `gh` (jangan pakai `--allow-write`).

Di **VPS** (sebagai user deploy) — kunci privat tidak pernah meninggalkan server:

```sh
ssh-keygen -t ed25519 -f ~/.ssh/kran_deploy -N '' -C 'kran deploy key (read-only)'
cat ~/.ssh/kran_deploy.pub
```

Di **mesin pengembang** (gh CLI), dengan isi `.pub` di atas:

```sh
gh repo deploy-key add ~/.ssh/kran_deploy.pub --repo nferdazel/kran --title 'vps-read-only'
```

> **Peringatan nyata (dari `gh` sendiri):** deploy key yang ditambahkan lewat `gh` terikat pada token
> otentikasi yang sedang dipakai. Kalau aplikasi/token GitHub CLI itu dicabut, kunci ini **ikut
> terhapus**. Untuk kunci deploy produksi, menambahkannya lewat UI GitHub (Settings → Deploy keys)
> lebih tahan lama. Pilih salah satu dengan sadar.

Di `~/.ssh/config` **VPS**:

```
Host github-kran
  HostName github.com
  User git
  IdentityFile ~/.ssh/kran_deploy
  IdentitiesOnly yes
```

Lalu env server: `KRAN_GIT_URL=github-kran:nferdazel/kran.git`.
Verifikasi: `ssh -T git@github-kran` — GitHub menjawab otentikasi berhasil dan **tidak** memberi shell.

## B. Hook webhook (sha256, bukan sha1)

Secret dibuat **di server** dan tidak pernah masuk repo:

```sh
openssl rand -hex 32    # simpan ke webhook.json (mode 600)
```

Daftarkan hook di GitHub (payload JSON supaya bentuknya tidak salah):

```sh
gh api repos/nferdazel/kran/hooks --input - <<'JSON'
{
  "name": "web",
  "active": true,
  "events": ["push"],
  "config": {
    "url": "https://<endpoint-webhook-anda>/hooks/kran",
    "content_type": "json",
    "secret": "<SECRET_DARI_LANGKAH_OPENSSL>",
    "insecure_ssl": "0"
  }
}
JSON
```

Bentuk hook di sisi server sudah ada contohnya: `ops/webhook/hook.kran.json.example` (id `kran`,
`payload-hmac-sha256`, argumen `repository.name` + `ref`). Spec §21.7 mencatat 4 hook lama di server itu
memakai **sha1** — jangan diwariskan.

Verifikasi tanpa memicu deploy: `gh api repos/nferdazel/kran/hooks` untuk melihat daftar, lalu push ke
**branch non-`main`** dan pastikan `deploy-vps.sh` menolaknya lewat ref-guard (§21.4) tanpa efek samping.

## C. Berkas env di server (mode 600)

Salin dari `ops/env/kran-prod.env.example` ke `/srv/qouver/apps/kran/env/kran-prod.env`, isi nilai
nyata. Variabel yang dibaca kode: `KRAN_DATABASE_URL`, `KRAN_DB_POOL_SIZE`,
`KRAN_DB_ACQUIRE_TIMEOUT_MS`, `KRAN_DB_STATEMENT_TIMEOUT_MS`, `KRAN_DB_VALIDATE_ON_ACQUIRE`,
`KRAN_APP_NAME`. Variabel untuk skrip deploy: `KRAN_GIT_URL`, `KRAN_APP_DIR`, `KRAN_HEALTH_URL`,
`KRAN_ENV_FILE` (opsional, default `$KRAN_APP_DIR/env/kran-prod.env`).
**`KRAN_PORT` dan `KRAN_BIND_HOST` wajib ada**: biner tidak membacanya sendiri, unit systemd yang
meneruskannya ke flag `--port`/`--address` (lihat T-045 temuan 8).
**Tidak ada nilai bisnis di sini** — semuanya dari parameter DB (spec §10).

## D. Fakta server (recon read-only, 15 Okt 2026)

Diperiksa langsung, bukan diasumsikan:

| Fakta | Nilai |
|---|---|
| Postgres | container Podman `qouver-postgres`, `127.0.0.1:5432`, superuser `qouver` |
| Sistem lama yang berjalan | container `cbs-api` → **127.0.0.1:8095**, `cbs-web` → 127.0.0.1:3005 |
| `/srv/qouver/apps/cbs` | **sudah ada** (65 MB; `env/ logs/ monorepo/ scripts/`, sejak 2 Sep 2026) |
| DB terkait sistem lama | `cbs` (14 MB), plus `cbs_verify*` — **jangan disentuh** |
| Direktori aplikasi kita | `/srv/qouver/apps/kran` (belum ada; default skrip sudah ke sana) |

Konsekuensi: direktori aplikasi kita **wajib** berbeda dari `/srv/qouver/apps/cbs` — bukan sekadar
preferensi nama, melainkan menghindari tabrakan dengan yang sudah ada. Port 8095 memang **diambil alih**
unit kita saat peralihan (keputusan pemilik 16 Okt 2026, D-043: replace di tempat, domain tetap
`cbs.qouver.com`), jadi urutannya: hentikan container lama → jalankan unit KRAN → arahkan upstream Caddy.

## D2. Keputusan yang sudah diambil (16 Okt 2026)

- **Domain**: tetap `cbs.qouver.com` — dipakai KRAN setelah peralihan; DNS tidak disentuh (D-043).
- **Skema peralihan**: **replace** di tempat. `kran-api` mengambil `127.0.0.1:8095`, `kran-web` `3005`,
  yaitu port yang sekarang dipegang `cbs-api`/`cbs-web` (D-043). Karena itu default `8095` di
  `deploy-vps.sh`/`smoke.sh` disengaja.
- **Sisa sistem lama**: unit lama dihentikan + **di-mask**, tidak dihapus; yang benar-benar **masih ada**
  sebagai jalan mundur: DB `cbs`, image lama, dan direktori `/srv/qouver/apps/cbs`. Container
  `cbs-api`/`cbs-web` sudah dihapus dan DB `cbs_verify*` sudah di-drop (O-054 + O-002, 16 Okt 2026), jadi
  "kembali ke sistem lama seutuhnya" **bukan** pilihan: pemulihan `cbs_verify*` hanya lewat backup harian
  02:00 hari itu (`/srv/qouver/backups/postgres/daily/*_2026-10-16_02-00-01.dump`) — jalur yang sudah
  diuji restore, bukan diasumsikan.
- **Unit systemd TIDAK dipasang oleh `deploy-vps.sh`** — skrip hanya menjalankan `daemon-reload` +
  restart. Kalau `ops/systemd/*.service` berubah, berkasnya harus **disalin manual** ke
  `~/.config/systemd/user/` lalu `daemon-reload`, kalau tidak perubahan itu hanya ada di repo.
  Per 16 Okt 2026 unit **produksi masih versi lama**: `kran-api.service` belum memuat
  `RestartPreventExitStatus=2` (T-054), jadi berkas KEK yang salah masih akan restart-loop tiap 3 detik
  sampai unit itu disalin.
- **Yang masih menunggu manusia**: latihan `deploy-vps.sh` manual di server (T-013) dan izin sebelum
  push pertama ke `main` (push = webhook = deploy).

## E. Verifikasi setelah terpasang

1. `gh api repos/nferdazel/kran/hooks` — hook ada, `content_type: json`, `insecure_ssl: "0"`.
2. Push ke branch non-`main`: webhook terpanggil, deploy ditolak ref-guard, tidak ada perubahan state.
3. Latihan `deploy-vps.sh` manual di server (T-013): health gate `/readyz` lulus dan `.deployed_rev`
   terisi.
4. Baru setelah itu merge ke `main` — dan itu tetap keputusan manusia (AGENTS.md §3).

## F. Peralihan ke KRAN — yang benar-benar dilakukan (16 Okt 2026, D-043)

Dijalankan di server, urutannya sengaja begini supaya domain tidak pernah mati lebih lama dari
pergantian blok Caddy. Sebelum ini KRAN berlatih di `8098`; port itu hanya sementara.

```
# 1. Bebaskan 8095 dari sistem lama. Stack lama dikelola **quadlet systemd**, bukan podman polos:
#    `systemctl --user stop cbs-api` — `podman stop` saja akan dihidupkan kembali unitnya.
systemctl --user stop cbs-api
# 2. KRAN pindah ke port final: KRAN_PORT=8095 di env, lalu restart unit.
systemctl --user restart kran-api        # /readyz di 8095 harus 200 sebelum lanjut
# 3. Blok Caddy: ganti `cbs.qouver.com` dengan blok A `ops/caddy/Caddyfile.kran.example`,
#    lalu (sekali saja) atur label SELinux untuk akar web:
semanage fcontext -a -t httpd_sys_content_t "/srv/qouver/apps/kran/web(/.*)?"
restorecon -RF /srv/qouver/apps/kran/web
caddy validate --config /etc/caddy/Caddyfile && systemctl reload caddy
#    Header CSP sengaja hanya `frame-ancestors 'none'`: kebijakan lengkapnya dari `<meta>` ber-hash
#    (D-045). Jangan tambahkan `script-src` di header, dua kebijakan CSP diirisan.
# 4. Verifikasi domain, baru matikan web lama:
#    / dan /login = 200, /api/v1/auth/session = 401 (galat bergaya KRAN)
systemctl --user stop cbs-web
# 5. Jangan biarkan container lama bangkit lagi setelah reboot, tetapi jangan hapus apa pun (D-043):
systemctl --user mask cbs-api cbs-web
systemctl --user enable kran-api         # kran-worker menyusul sampai perannya ada (O-060)
```

Jalan mundur (semua berkas lama utuh):

```
systemctl --user unmask cbs-api cbs-web && systemctl --user start cbs-api cbs-web
# lalu kembalikan blok cbs.qouver.com ke `reverse_proxy 127.0.0.1:3005` + reload caddy
# backup Caddyfile ada di /etc/caddy/Caddyfile.bak.kran-<stamp>
```

Fakta yang membuat peralihan ini tidak lurus (semuanya ketemu di server, bukan di gate lokal):

| Fakta | Konsekuensi |
|---|---|
| Host Rocky 9 tidak punya `libpq`; biner dibangun di image Debian | `deploy-vps.sh` mem-*vendor* `libpq.so.5`, `libldap-2.5.so.0`, `liblber-2.5.so.0`, `libsasl2.so.2` dari image ke `$APP_DIR/lib` (nama = soname) dan unit memakai `LD_LIBRARY_PATH`. Alternatif rapi: `dnf install libpq` di host (butuh root) lalu hapus blok vendor |
| Biner tidak membaca `KRAN_PORT` | unit wajib meneruskan `--port=${KRAN_PORT} --address=${KRAN_BIND_HOST}`; tanpa itu app memakai 8080 — port yang di host ini dipakai container lain (crash-loop) |
| `webhook.service` tidak mewarisi `EnvironmentFile` unit | `deploy-vps.sh` memuat `$APP_DIR/env/kran-prod.env` sendiri; kalau tidak, deploy dari push gagal `KRAN_DATABASE_URL kosong` |
| Direktori `web` diganti tiap deploy (`mv web.new web`) | direktori baru mewarisi label SELinux induknya (`var_t`) → Caddy (user `caddy`) menerima 403/404. `deploy-vps.sh` sudah memanggil `restorecon -RF "$APP_DIR/web"`; yang **wajib** ada sekali di server adalah aturan `semanage fcontext` di atas — tanpa aturan itu `restorecon` justru mengembalikan label ke `var_t` |
| Stack lama = quadlet systemd | `podman stop` tidak cukup; hentikan lewat `systemctl --user stop cbs-*`, lalu `mask` supaya tidak bangkit saat reboot |
| Situs lain punya `handle /cbs/*` → 8095 | setelah peralihan, path itu menuju KRAN. Dicatat sebagai konsekuensi di O-054 |

Prosedur pemasangan dari nol (ringkas): buat role + DB (`kran_app`/`kran`), salin env, pasang unit,
`login` root sekali untuk `semanage fcontext`, lalu deploy pertama — ekstensi `pgcrypto`/`btree_gist`
dibuat oleh migrasi + bootstrap runner, jadi tidak perlu langkah manual di DB.
