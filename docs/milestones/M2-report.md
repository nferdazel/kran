# Milestone 2 — Deposit + Teller

Tanggal: 23 Oktober 2026
Status: **selesai** untuk kriteria spec §23 ("Transaksi tunai & PB, saldo realtime; alur teller
keyboard-only lulus a11y"), dengan batas yang dicatat di bawah.

## 1. Yang dikirim

| Area | Hasil |
|---|---|
| Rekening simpanan | `POST/GET /deposit/accounts`, nomor provisoris, saldo `account_balance`, gerbang cabang, idempotency (T-088a) |
| Transaksi tunai | Setor/tarik, jurnal double-entry **sinkron** dalam transaksi DB yang sama, saldo ≥ 0, imutabilitas (T-088b) |
| Pemindahbukuan | `deposit.transfer`, jurnal net-nol, kunci anti-deadlock, authz dua cabang, min_balance sumber (T-088c, D-124) |
| Sesi teller | Buka/tutup, vault, `cash_movement`, variance, gate tunai per `business_date`, audit/outbox (T-093, D-125) |
| UI teller | `/app/teller`: setor/tarik/PB, tinjauan inline, cari rekening lewat **nomor**, panel sesi kas, i18n id+en (T-088d/T-105/T-108) |
| Pintasan | F4/F5/F9 dari parameter `platform.ui.shortcut.*`, tanpa fallback hardcode (T-095) |
| E2E | Alur keyboard-only buka sesi → setor → tutup + axe 3 keadaan × 2 tema × 2 locale; fixture dev idempoten (T-109) |

## 2. Gate

- `./task ci` hijau (lihat `/tmp/ci-fase2.log`; ringkasan di `docs/PROGRESS.md`).
- Tinjauan independen: T-093 APPROVE (2 putaran), T-088a/b/c APPROVE, T-091/T-092 APPROVE.
- Mutation check tercatat untuk invarian uang: saldo ≥ 0, debit vault, partial unique sesi,
  `FOR UPDATE` penutupan sesi (T-093).
- E2E: 26 test (termasuk teller), axe tanpa pelanggaran serious/critical.

## 3. Deviasi dari rencana

1. **Cetak/PDF**: T-094a/094b **DONE** sebagai browser print (slip + statement A4, D-127);
   PDF server (Typst) tetap ditunda ADR-013b. Dot-matrix/passbook, audit cetak, dan kop lembaga
   tidak diklaim (`ACCEPTED-LIMITS §4b`).
2. **Pintasan F2 cari anggota** belum ada karena pencarian anggota belum ada. Command palette
   Ctrl+K dicatat T-110.
3. **Lookup nomor rekening** memakai endpoint daftar `?accountNo=` (D-126), bukan path baru;
   bentuk nomor tidak dipatok (D-123).
4. **Variance kas tanpa jurnal GL** (O-097) dan **top-up vault** sudah punya API (T-107) tetapi
   masih **tanpa jurnal GL**; vault produksi tetap harus diisi lewat runbook sebelum sesi kas.
5. **Format nomor rekening provisoris** (D-123/O-095): keputusan pemilik/compliance diperlukan
   sebelum data nyata.

## 4. Open items yang menentukan operasional

| Item | Dampak |
|---|---|
| O-095 / D-123 | Format nomor rekening belum final |
| O-097 | Kas teller & variance belum masuk GL |
| T-107 | Top-up vault teller tanpa GL (O-097) |
| T-094 | Cetak: browser print DONE; PDF server/dot-matrix ditunda |
| T-101 | Rekonsiliasi cache saldo vs ledger (Fase 3) |
| T-110 | Command palette Ctrl+K |

## 5. Risiko

- Gate sesi + UI dirilis bersamaan; tanpa vault produksi, panel sesi menampilkan
  `vault_not_configured` dan transaksi tunai tertahan (fail-closed, bukan data rusak).
- Tabel `deposit.account_balance` adalah cache; rekonsiliasi baru dijadwalkan Fase 3 (T-101).
- Test konkurensi sesi masih bisa false-pass bila mesin sangat lambat (batas dicatat di T-093).

## 6. Rekomendasi

1. Isi vault produksi lewat runbook dan sepakati format nomor rekening sebelum pilot data nyata.
2. Lanjut Fase 3: `daycloser` (EOD/EOM/EOY), lalu T-101 rekonsiliasi dan T-089/T-090 yang masih
   tertunda.
3. ADR-013b: putuskan mesin PDF server (Typst di worker) bila kebutuhan arsip/e-sign muncul.

## 7. Tindak lanjut pilot (23 Okt 2026)

- **Penerimaan Fase 2 terpenuhi** untuk deposit + teller: kriteria spec §23 (transaksi tunai & PB,
  saldo realtime, alur teller keyboard-only lulus a11y) tercatat di §1–§2 dan tidak diubah.
- Yang **belum** ada dan diterima untuk pilot: setup operator hanya API/CLI — tidak ada UI/API
  manajemen pengguna/peran, pembukaan rekening, administrasi periode/COA/pembalik, atau top-up vault;
  top-up vault tanpa penyetuju kedua (O-098) dan tanpa jurnal GL (O-097); satu `platform_admin` di
  produksi memegang maker + checker + kas + vault (O-102). Batas ini tercatat di
  `docs/ACCEPTED-LIMITS.md` §4c dan task lanjutan T-115…T-118 (`docs/BACKLOG.md`).
- Keputusan pemilik yang masih terbuka: bentuk final nomor rekening (O-095/D-123, kini sudah dipakai
  data pilot — O-104) dan pasangan SoD tambahan (O-102). Tidak ada keputusan semula yang diubah.
