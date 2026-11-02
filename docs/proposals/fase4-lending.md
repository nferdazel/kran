# Proposal — Fase 4: Lending

> Status: **disetujui pemilik 1 Nov 2026** (D-180): flat+efektif+anuitas, ambang DPD pola bank
> (0 / 1–90 / 91–120 / 121–180 / >180), PPAP sementara `NEEDS-COMPLIANCE-REVIEW`, urutan alokasi =
> parameter. T-161 dan T-162 boleh dimulai; T-166/T-167 menunggu angka final untuk pilot nyata. Belum ada task `READY`; belum ada
> kode. Sumber: spec §23 (Fase 4), §8 (modul `lending`), §11.6 (task day-close), §9.2 (golden test),
> §4 (REG-204 PPAP/kolektibilitas `V!`).
>
> **Status per 2 Nov 2026: SELESAI** — T-161…T-172 semuanya `DONE`, rilis v0.1.4–v0.1.8, bukti di
> [`docs/milestones/M4-report.md`](../milestones/M4-report.md). Badan proposal di bawah adalah memo
> sebelum keputusan dan sengaja tidak ditulis ulang; deviasi yang terjadi saat implementasi dicatat
> di M4 §6 (mis. T-170 jadi baca-saja; aksi tulis di T-173).

## Kenapa fase ini, dan kenapa tidak boleh dimulai tanpa keputusan

Deposit + teller + day-close sudah berjalan; `lending` adalah satu-satunya modul Fase 0–3 yang
sengaja dikosongkan. Target produk (MVP koperasi siap pilot, Fase 5) tidak bisa diuji tanpa siklus
pinjaman: kolektibilitas, PPAP, dan SHU semuanya bergantung padanya.

Yang **tidak** bisa saya putuskan sendiri (AGENTS §1.8, §8): semua angka dan aturan di bawah bertanda
`NEEDS-COMPLIANCE-REVIEW` sampai pemilik/compliance menetapkannya. Strukturnya parameter, nilainya
bukan:

| Hal | Keputusan pemilik/compliance | Dipakai di |
| --- | --- | --- |
| Metode bunga/margin yang dijual | flat / efektif / anuitas (syariah: bagi hasil, margin) — mana yang masuk pilot | jadwal angsuran, akrual |
| Ambang DPD → kolektibilitas 1–5 | batas hari per golongan (REG-204 `V!`) | task `lending.*`, laporan |
| Persentase PPAP/CKPN per golongan | angka penyisihan & apakah dihitung harian atau bulanan | task PPAP, jurnal |
| Denda keterlambatan & urutan alokasi pembayaran | pokok → bunga → denda atau sebaliknya | pembayaran angsuran |
| Kebijakan restrukturisasi & hapus buku | syarat, jurnal, izin | restruk, write-off |
| Akad syariah | baru relevan di Fase 8; fase ini konvensional saja | — |

Semua nilai itu masuk `lending/seeds/params.yaml` (maker-checker, effective-dated) — bukan konstanta.

## Urutan task yang diusulkan

Urutannya dibuat supaya tiap baris bisa ditutup dengan bukti mesin, bukan menunggu bagian lain.

| Usulan ID | Tujuan | Bergantung | Kriteria selesai (mesin) |
| --- | --- | --- | --- |
| T-161 | Skeleton modul `lending` + model: produk pinjaman (versi, effective-dated), akad/fasilitas, rekening pinjaman, jadwal angsuran; migrasi expand-only | T-142 (pola modul), D-002 | `archcheck` bersih, `itlending` dasar hijau, `MODULE.md` terisi, migrasi `--check` bersih |
| T-162 | Kalkulasi jadwal angsuran (flat, efektif, anuitas) di `domain/` dengan `Money`, tanpa float | T-161 | property test (jumlah angsuran = pokok + bunga; pembulatan tiap baris ≤ 1 sen; total tepat) + golden test vs fixture spreadsheet |
| T-163 | Pengajuan & persetujuan (maker-checker, 4-eyes, limit dari parameter), event `LoanSubmitted`/`LoanApproved` | T-162, T-086 (pola maker-checker produk) | `itlending` alur dua akun; self-approval 409; audit lengkap; izin `lending.loan.submit/approve` |
| T-164 | Pencairan: jurnal D akun pinjaman / K kas atau rekening simpanan; `Idempotency-Key` wajib | T-163 | Δ subledger = Δ GL, replay 200 bukan dobel, `LoanDisbursed` keluar sekali |
| T-165 | Angsuran: bayar tunai & PB, alokasi pokok/bunga/denda (urutan = parameter), update jadwal, statement | T-164 | property test alokasi; `itapi_lending` + Δ GL; angsuran terakhir menutup saldo tepat 0 |
| T-166 | Task day-close `lending.dpd_regrade`: hitung DPD, ubah kolektibilitas, event `CollectibilityChanged` | T-165, D-174 (pola task) | `itdaycloser_lending`: ambang dari parameter, idempoten per business date, audit per chunk |
| T-167 | Task PPAP/CKPN: penyisihan per golongan, jurnal + pembalik saat golongan membaik, frekuensi dari parameter | T-166 | Δ subledger PPAP = Δ GL; rekonsiliasi bersih; run kedua tidak menggandakan |
| T-168 | Restrukturisasi & hapus buku (write-off) dengan jurnal, audit, izin khusus | T-167 | alur teruji: restruk mengubah jadwal tanpa memutus riwayat; write-off nol-kan saldo dengan jurnal; keduanya butuh alasan |
| T-169 | Permukaan API: rute, OpenAPI, izin, scoping cabang | T-163…T-167 | `./task openapi` hijau, contract test, 403 lintas cabang teruji |
| T-170 | UI operator: pengajuan, daftar, detail (jadwal + tunggakan), pembayaran | T-169, DESIGN v2 | axe `moderate` 2 tema × 2 locale, keyboard-only, visual baseline baru |
| T-171 | Laporan & kontrol: daftar tunggakan, aging DPD, daftar PPAP, rekonsiliasi | T-167 | angka cocok dengan subledger pada fixture tetap |
| T-172 | Perluas simulasi & benchmark EOD dengan pinjaman; laporan M4 | T-166, T-167 | `itdaycloser_sim` mencakup pinjaman; bench 100k simpanan + 50k pinjaman (target spec §1.4) |

## Non-goals fase ini

- Syariah (akad, nisbah, bagi hasil) → Fase 8; jangan setengah memasang struktur yang belum dipakai.
- BMPK/KPMM/laporan OJK BPR → Fase 7.
- Integrasi SLIK/Dukcapil → Fase 9.
- Mesin invariant lintas-parameter umum (O-041 masih ditunda; pemicunya belum ada).

## Risiko yang sudah terlihat

1. **Angka REG-204 belum terverifikasi** (`V!`). Sampai pemilik menetapkan, semua seed bertanda
   `NEEDS-COMPLIANCE-REVIEW` dan laporan wajib menyebutnya. Ini bukan penghalang implementasi
   struktur, tetapi penghalang pilot dengan data nyata.
2. **Golden test butuh fixture tervalidasi** (spreadsheet akunting). Tanpa itu, T-162/T-167 hanya
   diuji terhadap dirinya sendiri — hijau yang tidak membuktikan apa pun.
3. **Beban EOD** bertambah dua task berat (regrade + PPAP) ke 100k rekening; benchmark T-172 harus
   dijalankan sebelum menyatakan target §1.4 tercapai.

## Yang saya minta dari pemilik

1. Setujui (atau koreksi) urutan task di atas → saya ubah jadi baris `READY` di `BACKLOG.md`.
2. Tetapkan minimal: metode bunga pilot, ambang DPD, persentase PPAP, urutan alokasi pembayaran.
   Kalau belum siap, saya mulai dari **T-161 + T-162** yang strukturnya tidak bergantung angka.
