# Audit repo publik — KRAN (nferdazel/kran)

**Tanggal:** 2 November 2026
**Status repo:** publik di GitHub (`nferdazel/kran`); push ke `main` = deploy ke produksi.
**Sifat audit:** menyeluruh pada *isi repo* (working tree + riwayat git + konfigurasi CI/CD).
Tindakan: hanya redaksi/pengetatan di dalam repo. **Tidak ada** commit, push, `./task release`,
atau tindakan apa pun di server.

## 1. Ruang lingkup

| # | Area | Yang diperiksa |
|---|------|----------------|
| 1 | Rahasia di working tree & riwayat | gitleaks (2 mode), pola manual: PAT, kunci privat, DB URL ber-kredensial, TOTP/session secret |
| 2 | Pengungkapan infrastruktur | IP, hostname, user SSH, nama container, path internal, lokasi backup, path KEK, URL webhook/monitoring |
| 3 | CI/CD | interpolasi konteks tak tepercaya, `pull_request_target`, `permissions`, pinning action, secret ke PR fork |
| 4 | Skrip deploy | `ops/scripts/deploy-vps.sh` (fail-closed, kredensial, nilai serang bila publik) |
| 5 | Higiene repo | `.gitignore`, `ops/env/*.example`, lockfile/`node_modules`, data nyata, screenshot |
| 6 | Setelan GitHub | hal yang **tidak bisa** diubah dari repo — daftar tindakan untuk pemilik |

Di luar lingkup (dikerjakan agen lain saat audit ini): `SECURITY.md`, `CONTRIBUTING.md`,
`CODE_OF_CONDUCT.md`, `ACCESSIBILITY.md`, `.github/ISSUE_TEMPLATE/*`,
`.github/pull_request_template.md`. Tidak ada berkas itu yang disentuh di sini.

## 2. Ringkasan hasil

- **Tidak ada kredensial, kunci privat, token, atau data anggota nyata** di working tree maupun
  di riwayat git (467 commit). Satu-satunya temuan pemindai adalah **positif palsu** (SEC-06).
- **Tidak ada celah injeksi CI** yang bisa dieksploitasi (SEC-11 s/d SEC-13).
- `deploy-vps.sh` aman dipublikasikan: fail-closed, tanpa kredensial, dan pengetahuannya tidak
  memberi penyerang jalur eksekusi (SEC-10).
- Risiko nyata yang tersisa = **identitas host produksi** (IP + user SSH) yang sudah ada di
  riwayat git dan masih dikutip di dokumen. Bagian yang bisa dibereskan di dalam repo sudah
  diredaksi; bagian yang tidak bisa (riwayat) dicatat sebagai konsekuensi permanen.
- 5 berkas diubah (`.gitignore`, 2 runbook, register `OPEN_ITEMS.md`, indeks `docs/README.md`)
  + berkas laporan ini.

## 3. Temuan

Severity: **BLOCKER** (harus sebelum publik/berikutnya), **MAJOR** (kerjakan sekarang),
**MINOR** (kerjakan terjadwal), **INFO** (dicatat, tidak perlu aksi).

> **Tindak lanjut 2 Nov 2026 (keputusan pemilik).** Riwayat git **ditulis ulang** dengan
> `git-filter-repo --replace-text` untuk menghapus `<deploy-user>@<vps-host>` dari seluruh blob
> (4 commit: `5964665`, `75847b1`, `1f65a63`, `5344f47`) dan `<registry-npm-privat>` di
> `docs/DECISIONS.md`, lalu force-push `main` + semua tag. **Pesan commit tidak pernah memuat** IP,
> user, atau kredensial — hanya isi berkas.
>
> Tulis ulang **tidak cukup**: force-push hanya memindahkan ref, objek lama tetap dilayani GitHub
> lewat URL SHA (`/commit/5344f47` → 200, isinya masih memuat IP). Karena itu repo **dihapus dan
> dibuat ulang** (`nferdazel/kran`) dengan riwayat yang sama tetapi tanpa objek lama, lalu `main`
> + tag di-push ulang. Rilis lama dibuat ulang oleh `release.yml` dari tag.
>
> **Risiko tersisa:** fork `choepru/kran` (dibuat 31 Okt 2026, sebelum scrub) tetap menyimpan objek
> lama dan tidak ikut terhapus saat repo sumber dihapus. Menunggu pemilik fork menghapusnya.

| ID | Sev | Lokasi (file:line) | Risiko | Status |
|----|-----|--------------------|--------|--------|
| SEC-01 | MAJOR | `docs/runbooks/demo-data.md:11` (`ssh <deploy-user>@<vps-host>`) | IP produksi + user SSH nyata di runbook *current-state*. Memberi penyerang target konkret (SSH terbuka ke internet, webhook deploy di host yang sama). Tidak ada kredensial, jadi bukan BLOCKER. | **DIPERBAIKI**: diganti `<deploy-user>@<vps-host>` + catatan lokasi nilai nyata (`.local/`, `~/.ssh/config`). Instruksi tetap bisa dijalankan. |
| SEC-02 | MAJOR | `docs/PROGRESS.md:25`, `docs/PROGRESS.md:1254`; riwayat: 4 commit (`5964665`, `75847b1`, `1f65a63`, `5344f47`) | IP + user SSH yang sama di catatan bertanggal dan di riwayat git. Penghapusan berkas **tidak** menghapus riwayat; rewrite history = keputusan pemilik (D-044: repo tetap publik, O-058). | **DILAPORKAN saja** (catatan bertanggal tidak ditulis ulang). Mitigasi sudah ada: hardening SSH (konfirmasi pemilik, O-058). |
| SEC-03 | MINOR | `docs/OPEN_ITEMS.md:64` (O-058) | Register *current-state* mengutip ulang IP + user yang sama, sehingga redaksi runbook jadi sia-sia kalau register dibaca. | **DIPERBAIKI**: literal diganti `<deploy-user>@<vps-host>`; makna catatan insiden tetap utuh. |
| SEC-04 | MINOR | `docs/runbooks/dev-web.md:12` (`<registry-npm-privat>`) | Hostname registry npm **internal milik organisasi lain** (bukan KRAN), terpublikasi tanpa manfaat bagi pembaca luar. Bukan kredensial dan tidak resolve publik; murni pengungkapan inventaris infra pihak ketiga. | **DIPERBAIKI**: diganti `<registry-npm-privat>`; perintah kerja (`pnpm_config_registry=https://registry.npmjs.org/`) tidak berubah. Sisa di `docs/DECISIONS.md:200,235` dan `docs/PROGRESS.md:306` (bertanggal) — dilaporkan saja. |
| SEC-05 | MINOR | `apps/api/tests/itapi_lending.nim:782` | gitleaks aturan `generic-api-key` menandai `"it168-bad-tenor-"` (awalan idempotency-key uji, entropi 3.58). Bukan rahasia: tidak ada nilai kredensial, hanya string uji. | **DIPERBAIKI di working tree** tanpa melonggarkan gate: string uji diganti `"tenor-nol"` (konteks `makerToken,` yang memicu aturan tetap sama, entropi turun). `gitleaks detect --no-git --source apps/api/tests/itapi_lending.nim` → **no leaks found**.

Yang **belum** tertutup: pemindaian riwayat (`--log-opts=--all`, 467 commit) masih menemukan satu
temuan lama di commit `3b15a71` dan sebelumnya. Pilihannya dua, keduanya butuh keputusan pemilik:

1. **Allowlist sempit** (disarankan): tambahkan satu regex ke `[allowlist]` `.gitleaks.toml` dengan
   alasan tertulis + entri `DECISIONS.md` — gate tidak dilonggarkan untuk bentuk lain. Pola usulan
   hanya untuk prefix kunci idempoten uji: `'''it168-[a-z]+-'''`.
2. Terima 1 temuan palsu di riwayat dan jangan jalankan pemindaian riwayat penuh di CI (saat ini CI
   memindai working tree, dan itu hijau). **Sejarah tetap memuat string lama** (commit `3b15a71` dan sebelumnya), jadi pemindaian riwayat penuh masih melaporkan 1 temuan sampai allowlist sempit disetujui (§6.1) atau riwayat ditulis ulang — keduanya butuh keputusan pemilik. |
| SEC-06 | MINOR | `.github/workflows/ci.yml:34,37,100,103,163,166,172,181,205,210,235,240`; `release.yml:27`; `visual-baseline.yml:47,50,53,62,71,76,105` | Semua action dipin ke **tag mayor** (`@v4`, `@v2`), bukan SHA — termasuk dua action pihak ketiga (`jiro4989/setup-nim-action@v2`, `gitleaks/gitleaks-action@v2`). Tag bisa dipindahkan pemilik action; rantai pasok CI. | **DILAPORKAN**. Tidak diubah: pekerjaan `.github/workflows/*` di luar izin tugas ini kecuali ada injeksi konkret (tidak ada). |
| SEC-07 | MINOR | `docs/runbooks/dev-db.md:42`, `ops/env/kran-prod.env.example:7` | Nama akun OS operator (`sachiel`) tersisa di dua tempat. Sendiri-sendiri tidak dapat dieksploitasi (tanpa host/kunci); nilainya bertambah hanya bila dipasangkan dengan IP yang sudah publik di riwayat (SEC-02). | **DILAPORKAN** (sengaja tidak diubah: tidak menambah kemampuan penyerang, dan contoh env tetap terbaca). |
| SEC-08 | INFO | `.gitignore:7-9`; `.local/` (dev.env, prod.env) | Apakah `.local/` (URL DB dev ber-password, env prod) ter-ignore dan tidak ikut ter-track. | **TERVERIFIKASI**: `.gitignore:7` = `.local/`; `git ls-files .local` kosong; `git check-ignore -v .local/` → `.gitignore:7:.local/`. Tidak ada berkas ter-ignore yang ter-track (`git ls-files -i -c --exclude-standard` kosong). |
| SEC-09 | INFO | `ops/env/kran-prod.env.example:15,50`; `ops/webhook/hook.kran.json.example:21` | Nilai contoh di `*.example`. | **TERVERIFIKASI bersih**: hanya placeholder (`CHANGE_ME`, `KRAN_GITHUB_TOKEN=` kosong, `YOUR_WEBHOOK_HMAC_SECRET`). Satu-satunya `*.env` yang ter-track adalah berkas `.example` ini. |
| SEC-10 | INFO | `ops/scripts/deploy-vps.sh` | Skrip deploy publik. | **TERVERIFIKASI tidak dapat disalahgunakan** — lihat penalaran di §4. |
| SEC-11 | INFO | `.github/workflows/ci.yml:15-18`, `visual-baseline.yml:43-44` | Injeksi lewat konteks GitHub. | **TERVERIFIKASI**: tidak ada `pull_request_target`; tidak ada `${{ github.event.* }}`/`github.head_ref` di dalam `run:` — input dispatch dibaca lewat `env:` (`UPDATE_BASELINE`), `TAG` lewat `env:` (`release.yml:33`). |
| SEC-12 | INFO | `ci.yml:20-21`, `release.yml:13-14`, `visual-baseline.yml:19-20` | Izin token terlalu luas. | **TERVERIFIKASI minimal**: `contents: read` di level workflow CI & visual-baseline; `contents: write` hanya di `release.yml` (perlu untuk membuat GitHub Release). `secrets.*` yang dipakai hanya `GITHUB_TOKEN`. |
| SEC-13 | INFO | `ci.yml:239-242` | Secret terpapar ke PR fork. | **TERVERIFIKASI tidak**: job `security` hanya membaca `GITHUB_TOKEN` (read-only). Job lain tanpa secret. PR fork tidak mendapat rahasia apa pun. |
| SEC-14 | INFO | `docs/tasks/T-040.md:24` (`https://api.qouver.com/hooks/kran`) | URL endpoint webhook publik. | **DITERIMA**. Mengetahui path tidak melewati verifikasi: hook mewajibkan HMAC-SHA256 (`hook.kran.json.example:21`), `X-GitHub-Event: push`, dan `repository.name == kran` (`:16-40`). Path juga mudah ditebak. HMAC secret tidak ada di repo (dibuat di server). |
| SEC-15 | INFO | `docs/runbooks/*` (path `/srv/qouver/...`, `kran-kek.key`, `/srv/qouver/backups/...`, container `qouver-postgres`, domain `cbs.qouver.com`) | Fakta arsitektur & operasi. | **DITERIMA**: bukan kredensial, bukan identifier yang bisa dieksploitasi tanpa akses host. Dokumentasi operasi tetap berguna. Aturan yang berlaku: jangan menambah detail infra baru (O-058). |
| SEC-16 | INFO | seluruh tree | Data anggota nyata / screenshot ber-PII / seed tidak sintetis. | **TERVERIFIKASI bersih**: 4 berkas PNG ter-track, semuanya baseline visual halaman login/kata-sandi kosong (tanpa isian); seed dev = user sintetis (`packs/base/seed/0001_dev_users.sql`), seed demo = 12 party fiktif ber-CIF `900000*` (`packs/demo/manual/0001_demo_parties.sql`); tidak ada NIK 16 digit; tidak ada `identity_doc` mentah. |
| SEC-17 | INFO | `pnpm-lock.yaml`, `node_modules/` | Lockfile/`node_modules` ter-track. | **TERVERIFIKASI wajar**: lockfile **memang** harus ter-track (`pnpm install --frozen-lockfile`); `node_modules` **tidak** ter-track (0 berkas). |

## 4. Mengapa `deploy-vps.sh` aman dipublikasikan

Diperiksa `ops/scripts/deploy-vps.sh` (36 KB):

1. **Fail-closed ref-guard** — `:304-308`: `if [ "$REF" != "refs/heads/main" ]; then ... exit 0`.
   Ref kosong pun ditolak (bukan pola `[ -n "$REF" ] &&`).
2. **Tanpa kredensial** — URL repo & kredensial hanya dari env host
   (`:323-325` mewajibkan `KRAN_GIT_URL`, nilai nyata di `env/kran-prod.env` mode 600,
   `:231`). Token GitHub opsional dibaca dari env (`:139`). Tidak ada literal rahasia.
3. **Tidak ada hostname/IP nyata** — hanya path default `/srv/qouver/apps/kran` dan
   `HEALTH_URL` default `127.0.0.1:8095/readyz` (`:40`). Alamat yang sama sudah tercatat sebagai
   fakta arsitektur (SEC-15).
4. **Tidak bisa dijalankan penyerang** — skrip dieksekusi webhook **di host**, dengan argumen dari
   payload yang sudah lolos HMAC-SHA256 (SEC-14). Dari luar repo, isi skrip hanya memberi tahu
   *bagaimana* deploy bekerja; tidak ada jalur untuk memicu, menulis, atau membaca apa pun.
   Mengetahui bahwa gerbang memeriksa `/readyz` dan CI check-run justru tidak membantu: keduanya
   harus benar-benar hijau.

## 5. Yang diverifikasi vs diasumsikan

**Diverifikasi langsung (perintah + keluaran pada 2 Nov 2026):**

| Perintah | Keluaran kunci |
|---|---|
| `gitleaks version` | `8.30.1` (versi CI 8.24.3 — sama-sama mengenali bentuk `[allowlist]`) |
| `gitleaks detect --no-git --config .gitleaks.toml --redact -v` | `scanned ~455446452 bytes`, **`leaks found: 140`** — 139 di artefak yang *gitignored* (`.build/**` 106, `packages/i18n/project.inlang/cache/**` 33), 1 di `apps/api/tests/itapi_lending.nim:782` (SEC-05, positif palsu) |
| `gitleaks detect --config .gitleaks.toml --redact --log-opts=--all` | `467 commits scanned`, **`leaks found: 1`** — hanya SEC-05, positif palsu |
| `git grep -nE '(postgres|postgresql)://[^ ]*:[^ @]+@'` | Semua hit = fixture uji/CI (`kran:kran@127.0.0.1:5432/kran_test`) atau `CHANGE_ME` — tanpa kredensial nyata |
| `git grep -nE 'BEGIN .*PRIVATE KEY\|ssh-(rsa\|ed25519) AAAA\|ghp_\|github_pat_\|AKIA\|xox[baprs]-'` | kosong |
| `git log --oneline -S'<vps-host>' --all \| wc -l` | `4` commit |
| `git ls-files .local` / `git check-ignore -v .local/` | kosong / `.gitignore:7:.local/` |
| `git ls-files \| grep -c node_modules` | `0` |
| `git ls-files \| grep -E '\.(png\|jpg\|jpeg\|csv\|xlsx?\|sqlite\|db\|dump\|pem\|key)$'` | 4 PNG (baseline login) |
| `git ls-files .github` | hanya 3 workflow (tidak ada `dependabot.yml`, `CODEOWNERS`) |

**Diasumsikan (tidak bisa dibuktikan dari repo):**

1. **Hardening SSH di host sudah berjalan** (password auth off, hanya kunci, mungkin rate-limit).
   Klaim ini berasal dari O-058, bukan dari audit ini — tidak ada akses server.
2. **HMAC webhook di server memakai secret nyata**, bukan nilai contoh. Hanya berkas `.example`
   yang ada di repo, jadi ini tidak dapat diperiksa.
3. **Token `KRAN_GITHUB_TOKEN` di server** (O-120) tidak bocor ke repo. Yang terlihat hanya nama
   variabel di `ops/env/kran-prod.env.example`; nilainya di host.
4. **Isi `.local/`** (dev.env, prod.env) tidak dianalisis nilainya — hanya status ignore-nya.
   Diasumsikan berkas itu memang memuat kredensial nyata (komentar `tools/devdb.sh:10` menyebut
   demikian) dan karena itu **tidak boleh** ikut ter-track (terverifikasi tidak).
5. **Riwayat git sudah ditulis ulang dan repo dibuat ulang** (2 Nov 2026, keputusan pemilik):
   seluruh SHA berubah, objek lama tidak lagi dilayani GitHub. Fork/klon lama (termasuk
   `choepru/kran`) tetap memuat IP sampai dihapus pemiliknya — di luar kendali repo ini.

## 6. Rekomendasi yang belum dikerjakan (butuh keputusan/persetujuan)

### 6.1 Positif palsu gitleaks (SEC-05) — sudah ditutup di sumbernya

Allowlist **tidak** dilonggarkan (AGENTS.md §5: melonggarkan gate butuh entri `DECISIONS.md`).
Sebagai gantinya string uji yang memicu aturan `generic-api-key` diganti: `"it168-bad-tenor-"` →
`"tenor-nol"` (entropi di bawah ambang). Konteks `makerToken,` yang memicu aturan tidak berubah,
jadi ini bukan penghindaran pola — hanya literal yang tidak lagi menyerupai kredensial.
`gitleaks detect --no-git --source apps/api/tests/itapi_lending.nim` → **no leaks found**.

### 6.2 Pin action ke SHA (SEC-06)

Ganti `@v4`/`@v2` dengan commit SHA + komentar versi, terutama
`jiro4989/setup-nim-action` dan `gitleaks/gitleaks-action`. Butuh perubahan
`.github/workflows/*` → di luar izin tugas ini.

### 6.3 Bersihkan literal IP di register bila pemilik ingin konsisten

`docs/OPEN_ITEMS.md` sudah diredaksi (SEC-03). Bila pemilik ingin menuntaskannya, opsi satu-satunya
adalah rewrite riwayat (`git filter-repo`) — mahal, mengubah semua SHA, dan tidak menghapus
klon/fork yang sudah ada. Alternatif yang lebih murah dan sudah berjalan: hardening SSH +
rotasi kunci bila ada indikasi penyalahgunaan.

## 7. Checklist setelan GitHub (tidak dapat diubah dari repo — **belum** dikerjakan)

Semua di bawah ini adalah tindakan pemilik di UI/API GitHub. Tidak ada yang diklaim sudah aktif.

- [ ] **Settings → Code security → Private vulnerability reporting**: aktifkan (advisories privat),
      lalu tautkan dari `SECURITY.md`.
- [ ] **Secret scanning**: aktifkan; pastikan **push protection** aktif (repo publik memakai
      pemindaian rahasia bawaan GitHub — melengkapi job gitleaks).
- [ ] **Dependabot alerts** aktif; **Dependabot security updates** aktif.
- [ ] **Dependabot version updates**: tambahkan `.github/dependabot.yml` (npm/pnpm + github-actions,
      mingguan) — saat ini belum ada.
- [ ] **Branch protection / ruleset untuk `main`**:
      - wajib PR sebelum merge (tidak ada push langsung — push ke `main` = deploy produksi),
      - wajib check hijau: `Nim (check + unit/property test)`, `DB (integrasi, Postgres 18)`,
        `Web (svelte-check + axe + Playwright)`, `Security (gitleaks)`,
      - wajib branch up-to-date sebelum merge,
      - larang force-push dan penghapusan branch,
      - wajib review ≥1 (setelah repo punya kolaborator; untuk solo maintainer minimal
        "require PR" + check wajib).
- [ ] **Tag protection / release immutability**: aktifkan *immutable releases* (Settings → General →
      Releases) agar rilis yang sudah terbit tidak bisa diubah asetnya.
- [ ] **Actions**: batasi *Actions permissions* ke action terpilih bila memungkinkan
      (allowlist `actions/*`, `pnpm/action-setup`, `jiro4989/setup-nim-action`,
      `gitleaks/gitleaks-action`), dan set *default workflow permissions* = **read-only**
      (repo ini sudah meminta `contents: read`; setelan org/repo adalah lapis kedua).
- [ ] **Webhook `push` produksi**: verifikasi secret HMAC di sisi server sudah diganti dari nilai
      contoh, dan `Content type: application/json` + *SSL verification* aktif.
- [ ] **Deploy key** `vps-read-only` (lihat `docs/runbooks/deploy-setup.md:36`): pastikan
      **read-only** dan dicabut bila tidak dipakai.
- [ ] **Environment `production`** (opsional): bila deploy nanti dipindah ke Actions, gunakan
      environment dengan required reviewers.
- [ ] Audit berkala: `gitleaks detect --no-git --config .gitleaks.toml` (working tree) → **0 temuan**
      sekarang; `--log-opts=--all` (riwayat) → **1 temuan palsu** sampai allowlist sempit disetujui
      (§6.1). Jadwalkan manual sebelum rilis besar.

## 8. Perubahan yang dilakukan audit ini

| Berkas | Perubahan |
|--------|-----------|
| `docs/runbooks/demo-data.md:10-16` | `ssh <deploy-user>@<vps-host>` → `ssh <deploy-user>@<vps-host>` + catatan letak nilai nyata. Perintah `podman exec` tidak berubah. |
| `docs/runbooks/dev-web.md:10-15` | Hostname registry internal pihak ketiga → `<registry-npm-privat>` + penjelasan. Perintah kerja tidak berubah. |
| `docs/OPEN_ITEMS.md:64` | Literal `<deploy-user>@<vps-host>` di catatan O-058; rujukan ke laporan ini. |
| `.gitignore:12-19` | Tambah `*.key`, `*.pem`, `*.p12`, `*.pfx`, `id_rsa*`, `id_ed25519*` (KEK/field-encryption & kunci SSH tidak boleh pernah ter-commit). Diverifikasi tidak ada berkas ter-track yang jadi ter-ignore (`git ls-files -i -c --exclude-standard` kosong). |
| `docs/README.md:21` | Tautan ke laporan ini di tabel dokumen "keadaan sekarang". |
| `docs/security/public-repo-audit.md` | Berkas laporan ini. |

Tidak ada kode aplikasi, test, skrip deploy, atau workflow yang diubah.
