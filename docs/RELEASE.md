# KRAN — Rilis & Versi

> Keputusan: **D-178** (1 Nov 2026). Alur ini diadaptasi dari `majadu` (T-033 di sana), dengan
> satu perbedaan penting: kran menutup celah yang di majadu masih terbuka — `release.yml`
> memverifikasi `VERSION == tag`, dan deploy punya gerbang CI yang fail-closed.

Status: aktif. `VERSION` adalah satu-satunya sumber versi; `./task release` melakukan bump,
changelog, gate, commit, dan tag. Tag adalah **penanda**, bukan pemicu deploy.

## Satu versi, lima tempat

`VERSION` (root, plain `X.Y.Z`) harus sama dengan:

| Berkas | Peran |
| --- | --- |
| `kran.nimble` | versi paket Nim |
| `package.json` | versi workspace pnpm |
| `apps/api/src/version_gen.nim` | `AppVersion`/`AppCommit` untuk `/healthz` + log startup |
| `apps/web/src/lib/version.ts` | `APP_VERSION`/`APP_COMMIT` untuk footer UI |

Dua berkas terakhir **dihasilkan** `tools/gen-version.sh` (dipanggil `./task build`) dan
**dikomit**. `./task check`/`check-fast` menjalankan `./task version-check`, yang gagal bila salah
satu dari lima nilai itu melenceng — jadi versi tidak bisa "lupa dinaikkan" diam-diam.

`KRAN_VERSION` (env/systemd) tetap menang atas nilai yang distempel, sehingga proses yang berjalan
tidak bergantung pada kapan binary dibangun.

## Alur rilis

Rilis **dikumpulkan per batch**, bukan per commit: satu tag menjalankan workflow rilis dan
menandai deploy yang menunggu CI penuh (~10–15 menit di GitHub Actions). Menandai setiap commit
hanya menghabiskan runner dan membuat `CHANGELOG.md` jadi derau. Aturan praktisnya: rilis saat satu
pekerjaan utuh selesai (satu task, satu batch perbaikan, atau sebelum fase baru dibuka).

```sh
./task release            # bump diturunkan dari Conventional Commits
./task release minor      # paksa minor (major|minor|patch)
./task release --no-push  # latihan: commit + tag lokal, tanpa push/gh
```

1. Working tree harus bersih; `VERSION` harus semver polos.
2. Bump tanpa argumen diturunkan dari commit sejak tag `v*` terakhir: `!:` atau
   `BREAKING CHANGE:` → major, `feat:` → minor, selain itu patch.
3. `VERSION`, `kran.nimble`, `package.json` dinaikkan; `tools/gen-version.sh` menstempel ulang.
4. `tools/gen-changelog.sh` menambah entri `CHANGELOG.md` (Keep a Changelog) dari commit:
   `feat` → Added, `fix` → Fixed, `perf`/`refactor` → Changed, `ops`/`ci`/`deploy` → Operations.
   Commit `chore: release*` dilewati. Berkas yang sama dipakai sebagai catatan GitHub Release.
5. Gate: `./task check-fast` + `./task build` + `./task test` + `./task e2e`, lalu
   `./task version-check` (D-194). Butuh `KRAN_DATABASE_URL` — diperiksa sebelum `VERSION` di-bump
   supaya kegagalan env tidak meninggalkan working tree setengah jadi.
   `--skip-check` ada untuk darurat dan **dicatat** di catatan rilis.
6. Commit `chore: release vX.Y.Z` (tanpa `-s`: repo ini tidak memakai DCO), tag **anotasi**
   `vX.Y.Z`, lalu `git push origin <branch> --follow-tags` dan `gh release create`.
7. `.github/workflows/release.yml` (trigger `tags: v*`) memverifikasi tag == `VERSION` (termasuk
   manifest dan berkas generated) lalu membuat GitHub Release secara idempoten; hanya tag terbaru
   yang diberi badge *Latest*.

**Push tag tidak men-deploy.** Deploy tetap dari push ke `main` lewat webhook →
`ops/scripts/deploy-vps.sh`. Commit rilis ikut ter-deploy karena ia ada di `main`.

## Gerbang CI di deploy

`deploy-vps.sh` menunggu check-run GitHub untuk SHA yang di-deploy sebelum menyentuh apa pun:

```
Nim (check + unit/property test)
DB (integrasi, Postgres 18)
Web (svelte-check + axe + Playwright)
Security (gitleaks)
```

Aturan: hanya `success` yang hijau (`skipped`/`neutral` = check tidak berjalan), satu nama dinilai
dari run terbaru, check yang hilang atau timeout = **gagal** (fail-closed). Perubahan yang hanya
menyentuh dokumen melewati gerbang karena CI juga tidak berjalan untuk path itu. Permintaan ke API
bersyarat (`If-None-Match`), jadi poll yang tidak membawa perubahan dijawab `304` dan tidak memakan
kuota — penting karena tanpa token batasnya 60 permintaan/jam per IP. Kalau kuota toh habis
(`HTTP 403`/`429`), gerbang membaca `X-RateLimit-Reset` dan menunggu sampai reset **sekali** (masih
di dalam anggaran tunggu) sebelum gagal; pesan gagalnya menyebut `KRAN_GITHUB_TOKEN`, karena token
read-only adalah obatnya (O-120).

| Variabel | Default | Arti |
| --- | --- | --- |
| `KRAN_GITHUB_REPO` | `nferdazel/kran` | repo yang check-run-nya dibaca |
| `KRAN_GITHUB_TOKEN` | — (opsional) | repo publik; token hanya menaikkan batas API |
| `KRAN_CI_WAIT_SECONDS` | `1800` | batas menunggu CI (deploy pertama yang memakai gerbang ini menunggu 14m04s) |
| `KRAN_SKIP_CI_GATE` | `0` | **darurat saja**; tercatat `WARN` di `deploy.log` |
| `KRAN_DEPLOY_LOCK_WAIT` | `900` | batas menunggu deploy lain selesai (bukan langsung gagal) |

Alasan gerbang ini ada: 1 Nov 2026 produksi menyajikan web dari 25 Okt selama ~6 hari. CI hijau,
API ter-deploy, tetapi build web di host mati di `corepack: command not found` dan tidak ada yang
memeriksa hasil deploy. Gerbang CI bukan pengganti cek hasil deploy; ia hanya memastikan deploy
tidak dimulai untuk commit yang sudah terbukti merah.

## Batas yang diketahui

- Nama job dicocokkan sebagai string. Mengganti nama job di `ci.yml` tanpa memperbarui
  `CI_EXPECTED` di `deploy-vps.sh` membuat gerbang timeout (fail-closed) — dicatat sebagai O-119.
- Gate rilis lokal mencakup test + e2e, tetapi tetap bukan `./task ci` penuh: `check-fast` melewati
  `nim check` penuh (D-077). Jaminan menyeluruh datang dari CI pada commit yang sama; deploy
  menunggunya.
- `CHANGELOG.md` tidak lahir dari rilis pertama yang sudah lewat; entri ditulis hanya oleh
  `tools/gen-changelog.sh`, jangan ditulis tangan.
