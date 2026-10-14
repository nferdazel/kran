# Runbook — pengembangan web (workspace TS)

Berlaku untuk `apps/web`, `packages/{config,i18n,ui}` (spec §7, §14–§17). Semua perintah
"harian" tetap lewat satu pintu `./task`; catatan di sini hanya untuk hal yang tidak ditangani
`./task`.

## Pintasan penting: registry npm

`~/.npmrc` di mesin dev menunjuk registry privat:

```
registry=https://artifactory.pegadaian.co.id/repository/npm-group-1/
```

Registry itu **tidak resolve** dari jaringan biasa (`NXDOMAIN`), dan `pnpm` mengabaikan
`npm_config_registry` (nama env yang dibaca pnpm adalah `pnpm_config_registry`). Untuk memasang /
memutakhirkan dependency, pakai:

```sh
pnpm_config_registry=https://registry.npmjs.org/ pnpm install --frozen-lockfile
```

Tanpa override itu, perintah akan mencoba artifactory, gagal, dan **menggantung sampai retry
habis** (bisa >10 menit).

## Memasang dependency & lockfile

```sh
pnpm_config_registry=https://registry.npmjs.org/ pnpm install --frozen-lockfile
```

- `pnpm-lock.yaml` di-commit dan dipakai CI (`--frozen-lockfile`). Versi dependency juga dipin
  eksak di `package.json` (spec §18.2), jadi lockfile dan manifest saling menguatkan.
- Menambah/mengubah dependency: jalankan install dengan override di atas, lalu ikat versinya
  (mis. `pnpm add -D -E <paket>`), dan periksa `git diff pnpm-lock.yaml`.
- Supply-chain policy (bagian dari pnpm di mesin ini) memverifikasi lockfile saat install; bila
  ia gagal karena metadata tidak lengkap, jalankan install **online** (bukan `--offline`).

## Menjalankan gate

```sh
./task e2e    # kontras token (vitest) + kompilasi Paraglide + svelte-check + Playwright
./task ci     # semua: Nim + web
```

`./task e2e` memanggil binary lokal di `node_modules/.bin` secara langsung, bukan lewat
`pnpm run`. Alasannya konkret: `pnpm run` memasang ulang dependency lebih dulu bila dianggap
tidak sinkron, dan install itu bisa menggantung di jaringan ini (lihat di atas). Binary lokal
deterministik dan tetap benar di CI setelah `pnpm install`.

## Browser Playwright

Sekali per mesin / versi Playwright:

```sh
cd apps/web && ./node_modules/.bin/playwright install chromium
```

`playwright.config.ts` sengaja memakai `reuseExistingServer: false`: tiap run membangun ulang dan
menyajikan build baru, supaya test tidak bisa "hijau" melawan server lama yang masih hidup.

## i18n

- Katalog: `packages/i18n/messages/{id,en}.json` (datar, key berprefiks namespace).
- Gate: `./task i18n` (`tools/i18ncheck`): key wajib ada di semua locale, placeholder konsisten,
  tanpa key yatim, key yang dipakai kode wajib ada di katalog.
- Plugin Paraglide di-vendor sebagai devDependency `packages/i18n` dan dirujuk
  `project.inlang/settings.json` dengan jalur lokal (bukan CDN), sehingga build tidak butuh
  jaringan.
