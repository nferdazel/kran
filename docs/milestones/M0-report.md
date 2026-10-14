# Laporan Milestone M0 — Fase 0 (fondasi)

Tanggal: **14 Oktober 2026**. Branch: `feat/fase0-fondasi` (21 commit di atas skeleton `5964665`,
**belum di-merge ke `main`** — push ke `main` = deploy, jadi merge hanya oleh manusia, AGENTS.md §3).

Fase 0 = deliverable spec §23 "skeleton jalan end-to-end". Semua task T-001…T-016 berstatus DONE;
tidak ada lagi task `READY` di backlog.

## 1. Yang selesai

| Task | Hasil | Commit |
|---|---|---|
| T-001 | Skeleton monorepo, `./task` satu pintu, CI verifikasi | `5964665` |
| T-002 | `shared/kernel`: Money/Rate fixed-point (10⁴, tanpa `float`), BusinessDate, Result, Clock, IdGen, AuditContext | `eafe5aa` |
| T-003 | `tools/archcheck`, `tools/lint-nomagic`, `tools/paramgen` + gate | `d3f1c67` |
| T-004 | Pool DB, runner migrasi expand-only, outbox/inbox, hash-chain audit | `613c8eb` |
| T-005 | Framework parameter: efektif-dated 5 scope, maker-checker, cache + NOTIFY | `6611a98` |
| T-006 | Auth + RBAC + audit context + branch scoping dasar | `ad3a13b` |
| T-007 | Kalender kerja + business date (state OPEN/CLOSING/CLOSED) | `3b2fa81` |
| T-008 | Skeleton HTTP Mummy + kontrak OpenAPI + klien TS + contract test | `f192783` |
| T-009 | Realtime: outbox → `NOTIFY` → hub → klien WS + resume token | `637230d` |
| T-010 | Shell SvelteKit: design token, tema, i18n Paraglide, gate axe | `66825e6`, `a8a1e8d` |
| T-011 | `tools/scaffold` + modul contoh `hello` | `15cd5ba` |
| T-012 | **Alur Fase 0 end-to-end**: login → maker-checker parameter → audit → realtime di UI | `1f681ac`, `a1b6dc5`, `c7f394c` |
| T-013 | `ops/` (berkas skrip saja; **belum pernah dijalankan di server**) | `219f9af` |
| T-014 | Spike ADR-002 (Mummy vs Prologue vs asyncnet) → keputusan pemilik: Mummy + WebSocket | `01094a1`, `38cdedb` |
| T-015 | Inventaris `cbs-core` (referensi, bukan port) | `73c6cd8` |
| T-016 | Lapisan application layanan parameter + guard drift | `fe9ec82` |

Bukti per task ada di `docs/PROGRESS.md`; rencana & kriteria T-012 di `docs/tasks/T-012.md`.

## 2. Gate (semua dijalankan, bukan klaim)

- `./task ci` → **exit 0, "== CI hijau"** (log: `.build`-tidak di-commit; angka di bawah).
- `./task check` → format 106 berkas, `nim check` 107 berkas, archcheck bersih, lint-nomagic bersih,
  paramgen sinkron, i18n 88 key × 2 locale tanpa key yatim, 7 skrip ops lolos `bash -n`.
- `./task openapi` → kontrak lolos lint (fail-severity warn), klien TS sinkron, typecheck hijau.
- `./task test` → **416 `[OK]`, 0 gagal** (unit + property + integrasi Postgres, 38 berkas test).
- `./task e2e` → kontras token 34, `svelte-check` 0 error/0 warning, Playwright **18 lulus**:
  axe `/` × 2 tema × 2 locale, keyboard-only shell, `flow.spec.ts` (alur dua konteks maker/checker
  dengan penanda `__guard` → nilai ACTIVE muncul di sesi maker **tanpa reload**; jejak audit memuat
  `param.submit` + alasan pengguna & `param.approve`; Keluar → `/login`; axe `/login` + `/app`).

## 3. Review independen (AGENTS.md §4 butir 5)

Dijalankan sebagai **satu batch di akhir milestone** atas area kritis (rencana ini sudah dicatat di
`docs/PROGRESS.md` sejak T-002). Konteks bersih, prompt di `docs/agent/REVIEWER.md`; reviewer juga
menjalankan sendiri `./task check`/`./task test`.

| Ronde | Verdict | Temuan MAJOR | Status |
|---|---|---|---|
| 1 (`5964665..1f681ac`) | TIDAK APPROVE | (a) persetujuan ganda bisa lolos — 4-eyes bocor; (b) kombinasi parameter kebijakan sesi yang sah per-key membuat seluruh login gagal 500 tanpa amplop | ditutup D-027 + test yang GAGAL bila penjaganya dilepas |
| 2 (`1f681ac..a1b6dc5`) | TIDAK APPROVE | (a) jendela tanggal efektif **masa depan** (deterministik); (b) balapan dua persetujuan lintas-key | ditutup D-028 + 2 test baru (repo & HTTP) |

Temuan MINOR/pertanyaan (ronde 1–2) tidak ditutup di sini sesuai AGENTS.md §4 butir 6, tetapi
**dicatat**: O-034…O-042. Tidak ada temuan BLOCKER.

## 4. Deviasi dari spec (disengaja, tercatat)

1. **spec §19.1 SSE → WebSocket** (D-019): keputusan pemilik via E-001 = "Opsi A: Mummy + WebSocket";
   spec §19.1 sudah disesuaikan.
2. **Override Spectral sempit untuk respons 101** (D-022): WebSocket upgrade dijawab 101, sedangkan
   aturan `operation-success-response` menganggap hanya 2xx/3xx sukses. Override dibatasi ke satu
   operasi (`/api/v1/events/stream`) dengan alasan tertulis di ruleset.
3. **Harness test tanpa `--threads:on`** (O-040): balapan dua koneksi tidak bisa direproduksi; yang
   diuji adalah kontrak langkah aktivasi (dan test itu terbukti GAGAL bila penjaganya dilepas).
4. **`ops/` (T-013) belum dijalankan di server** — sesuai batas task (hanya berkas di repo); terkait
   O-013 (kontrak CLI `--role=migrate|ctl` belum ada di kode).

## 5. HUMAN-REVIEW-REQUIRED (AGENTS.md §8)

- **Kriptografi**: `modules/platform/infrastructure/password_hasher.nim` (PBKDF2, D-013) — vektor uji
  dihitung independen, area tetap wajib ditinjau manusia sebelum produksi.
- **Hash-chain audit**: `audit_log` + `audit_verify` (T-004) dan catatan O-037/O-038 (invarian kursor
  `seq` tidak tertulis; potensi alarm palsu verifikasi).
- **Authz/sesi + invariant kebijakan sesi**: D-027/D-028 mengubah jalur persetujuan parameter dan
  login; perlu tinjauan manusia sebelum dipakai dengan data nyata.

## 6. Risiko & item terbuka yang menghalangi produksi

`docs/OPEN_ITEMS.md` memuat **40 item** (O-001…O-042; nomor `O-020`/`O-021` tidak pernah dipakai).
Yang paling menghalangi:

| Item | Kenapa penting |
|---|---|
| O-001 | Nilai/pasal regulasi §4 bertanda `V?`/`V!` belum diverifikasi compliance — semua seed menyentuh aturan bisnis harus tetap `NEEDS-COMPLIANCE-REVIEW` |
| O-025 | `server.close()` SIGSEGV (Mummy 0.4.8 + ORC) → shutdown/restart bersih produksi belum terbukti |
| O-031 | Bootstrap user produksi belum diputuskan (siapa admin pertama, wajib ganti password) |
| O-034 | 403 `locked`/`inactive` sebelum verifikasi password → enumerasi akun |
| O-036 | Langganan realtime tidak divalidasi ulang setelah handshake → soket sesi yang dicabut masih menerima peristiwa |
| O-037, O-038 | Invarian kursor outbox & potensi alarm palsu verifikasi rantai audit |
| O-002, O-003, O-004 | DB non-prod ikut ter-backup, status data `cbs-core`, target volume & calon pilot (di luar repo) |

## 7. Kesimpulan & langkah berikut

Fase 0 tercapai: satu alur nyata **login → ajukan perubahan parameter (maker) → setujui (checker) →
jejak audit + peristiwa realtime di UI tanpa reload** berjalan di atas kerangka yang diminta spec
(clean architecture + gate otomatis, tanpa nilai bisnis di kode, uang lewat `Money`, i18n id+en,
a11y axe 2 tema, audit hash-chain, parameter dari DB).

**STOP** di batas milestone sesuai AGENTS.md §7. Yang saya minta dari pemilik:

1. **Keputusan membuka Fase 1** (spec §23) — atau perbaikan lebih dulu atas O-025/O-031/O-034/O-036.
2. **Keputusan mekanisme bootstrap user produksi** (O-031) — saya tidak menebaknya di kode.
3. Konfirmasi bahwa merge `feat/fase0-fondasi` → `main` dilakukan manusia (bukan saya).
