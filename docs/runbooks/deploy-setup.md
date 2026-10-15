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
`KRAN_APP_NAME`. Variabel untuk skrip deploy: `KRAN_GIT_URL`, `KRAN_APP_DIR`, `KRAN_HEALTH_URL`.
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
preferensi nama, melainkan menghindari tabrakan dengan yang sudah ada. Port 8095 juga masih dipegang
container `cbs-api`, jadi unit kita belum bisa memakainya sampai cutover (§21.5).

## D2. Yang belum diputuskan manusia

- **Domain**: `ops/caddy/Caddyfile.kran.example` masih memakai `cbs.qouver.com` (domain sistem lama
  selama transisi). Memilih domain KRAN itu keputusan pemilik domain, bukan efek samping rename.
- **Apa isi `/srv/qouver/apps/cbs` sekarang** dan apakah ia masih dipakai (container `cbs-api`/`cbs-web`
  jalan). Menentukan urutan cutover; bukan sesuatu yang diputuskan agen.
- **DB `cbs_verify*`** (7 basis data, 10–33 MB) tidak disentuh oleh rename; kepemilikannya perlu
  dikonfirmasi pemilik sebelum dianggap bagian dari apa pun.

## E. Verifikasi setelah terpasang

1. `gh api repos/nferdazel/kran/hooks` — hook ada, `content_type: json`, `insecure_ssl: "0"`.
2. Push ke branch non-`main`: webhook terpanggil, deploy ditolak ref-guard, tidak ada perubahan state.
3. Latihan `deploy-vps.sh` manual di server (T-013): health gate `/readyz` lulus dan `.deployed_rev`
   terisi.
4. Baru setelah itu merge ke `main` — dan itu tetap keputusan manusia (AGENTS.md §3).
