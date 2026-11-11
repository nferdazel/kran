# QA gate tooling (a11y + keyboard)

Dua runner, nol dependensi baru. Playwright dan `@axe-core/playwright` dipakai dari
`apps/web/node_modules` (sudah terpasang untuk e2e yang ada), di-resolve lewat path absolut.

```
tools/qa/a11y/           tracked
  a11y-matrix.mjs        matriks axe: layar x tema x lebar
  keyboard-flows.mjs     alur keyboard langkah-per-langkah
  config/
    mockup.json          baseline mockup (file://)
    app.json             gate app Svelte, 24 K-ID (http://127.0.0.1:5173)
    keyboard-mockup.json 4 alur yang bisa dijawab mockup
    keyboard-app.json    5 alur wajib; selector TODO = BLOCKED
  EXIT-CRITERIA.md       syarat lulus/gagal yang mengikat
  README.md              dokumen ini

.local/qa/results/       output .json + .md, gitignored (jangan diedit tangan)
```

Output sengaja tetap di `.local/qa/results/`, bukan di `tools/`: hasil run tidak ikut repo.
Target mockup `file:///…/.local/redesign/mockup/index.html` adalah artefak lokal yang gitignored.

## Menjalankan

```bash
# baseline mockup (sekarang)
node tools/qa/a11y/a11y-matrix.mjs    --config mockup --label baseline-mockup
node tools/qa/a11y/keyboard-flows.mjs --config keyboard-mockup --label keyboard-mockup

# gate app (setelah shell T-285 + sesi tersedia)
node tools/qa/a11y/a11y-matrix.mjs    --config app --label gate-t285 \
     --url http://127.0.0.1:5173
node tools/qa/a11y/keyboard-flows.mjs --config keyboard-app --label gate-t285 \
     --url http://127.0.0.1:5173
```

Opsi: `--themes light,dark`, `--widths 1440,360`, `--only <id>`, `--fixtures <file>`,
`--out <dir>`, `--label <name>`.

Exit code: `0` semua PASS, `1` ada FAIL, `2` hanya BLOCKED. `2` berarti belum hijau.

## Prasyarat

- `pnpm install` sudah pernah jalan di `apps/web` (Playwright + axe berasal dari sana).
- Browser Playwright ada di cache (`~/Library/Caches/ms-playwright`). Kalau belum:
  `cd apps/web && pnpm exec playwright install chromium`.
- Untuk gate app: dev server (`pnpm dev` di `apps/web`) + sesi login. Sekarang `/app/*`
  redirect ke `/login`, jadi combo-nya BLOCKED dengan sebab tertulis.

## Cara kerja

1. Tiap kombinasi memakai browser context baru, jadi tema/state tidak bocor antar combo.
2. Sumbu tema/lebar bisa berupa kontrol di halaman (`mode: control`, untuk mockup) atau
   viewport sungguhan (`mode: viewport`, untuk app). Setelah mengubah, runner **membaca
   balik** atributnya; kalau tidak berubah, itu FAIL - bukan dianggap terang/1440.
3. Layar harus benar-benar ada: selector jangkar dihitung dan dicek terlihat. Nol node = FAIL.
4. axe dijalankan **dibatasi ke region layar** (`include`). Violation di luar region dicatat
   terpisah (`outOfScope`), bukan dibuang.
5. Ambang gate: impact `critical`, `serious`, `moderate`. `minor` dicatat saja.

## Catatan mockup

- Mockup memakai CSS `zoom` supaya stage 1440/360 muat di satu halaman. Karena itu:
  - `data-w="360"` benar-benar memicu container query (reflow nyata), tapi viewport tetap
    1440; baseline ini tidak membuktikan reflow viewport 360.
  - Cincin fokus 2 px terbaca ~1.03 px karena zoom. Alur keyboard mockup memakai
    `minWidth: 1` + catatan; gate app tetap `minWidth: 2`.
- Drawer mockup: Escape menutup, tapi fokus tidak kembali dan tidak ada focus trap. Itu
  temuan baseline, bukan bug app.

## Konfigurasi

```jsonc
{
  "url": "http://127.0.0.1:5173",
  "axes": {
    "theme": { "mode": "storage", "storageKey": "kran-theme", "attr": "data-theme", "readFrom": "html" },
    "width": { "mode": "viewport" }
  },
  "auth": { "required": true, "redirectPath": "/login" },
  "fixtures": { "memberId": null, "loanId": null },
  "screens": [
    { "id": "K-08", "k": ["K-08"], "route": "/app/members/{memberId}",
      "expect": { "selector": "main, [role=main]", "min": 1, "visible": "h1" } }
  ]
}
```

`{memberId}` diisi dari `--fixtures` atau blok `fixtures`. Kosong = BLOCKED.

Sumbu yang didukung:

| mode | arti |
|---|---|
| `control` | klik kontrol di halaman (`control` selector, `{theme}`/`{width}` diganti), lalu baca `attr` |
| `viewport` | lebar viewport sungguhan |
| `storage` | seed `localStorage` lewat init script, lalu verifikasi `html[data-theme]` |
| `html` | set atribut `data-theme` di `<html>` |
| `none` | tidak ada sumbu (mis. target satu-tema) |

## Menambah layar/state

Tambah entri di `screens` dengan `id`, `k`, `route`/`scope`, dan `expect`. Untuk state
seperti drawer terbuka, pakai `setup: [{ "click": "<selector>", "wait": 220 }]`. Jangan
mengubah scope untuk menghindari violation; kalau sebuah violation bukan milik layar itu,
tulis alasannya di ticket.
