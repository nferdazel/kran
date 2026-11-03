# Proposal — Fase 5: Koperasi Pack

> Status: **usulan, belum dibuka** (3 Nov 2026). Tidak ada baris `READY` di `BACKLOG.md` sampai pemilik
> menyetujui urutan dan menjawab tabel keputusan di bawah. Sumber: spec §23 (Fase 5 — "`coop`
> (keanggotaan, SHU, RAT), laporan & rasio kesehatan"; kriteria selesai "MVP Koperasi siap pilot",
> "UAT koperasi sign-off"), §8 (tabel modul `coop`), §11.6 (task EOQ/EOY), §4 (REG-101, REG-104),
> `docs/compliance/register-validation.md`.

## Yang sudah ada, dan apa yang benar-benar kurang

Fase 1–4 sudah memberi hampir semua bahan mentah. Yang belum ada satu pun adalah konsep **anggota**:

| Sudah ada | Di mana |
| --- | --- |
| Rekening simpanan pokok/wajib dengan posting ke **ekuitas** `301.1`/`301.2` (bukan liabilitas) | `modules/ledger/migrations/0014_ledger_coop_savings.sql` (REG-101, D-195) |
| Penarikan/PB dari POKOK/WAJIB diblokir di handler (409 `savings_kind_locked`) | sama |
| `party` (CIF, identitas, KYC) — calon anggota sudah berupa data pihak | `modules/party` |
| Pinjaman, kolektibilitas, PPAP → dasar jasa usaha pada SHU | `modules/lending` |
| Day-close EOD/EOM/EOY dengan registry task | `modules/daycloser` |
| Cetak via browser (slip/statement) | D-127, `apps/web` |

Yang **tidak ada**: tabel anggota & siklus keanggotaan, kewajiban simpanan pokok/wajib per anggota,
tutup buku tahunan, perhitungan/distribusi SHU, paket laporan RAT, dan laporan rasio kesehatan.

Konsekuensi yang perlu dinyatakan di depan: hari ini `deposit` bisa menampung uang simpanan pokok,
tetapi sistem tidak tahu **siapa anggotanya**, berapa kewajibannya, atau apakah ia berhak atas SHU.
Itu celah yang Fase 5 tutup.

## Keputusan yang tidak boleh saya ambil sendiri

Semua di bawah adalah kebijakan institusi (AD/ART + RAT) atau angka regulasi yang belum terverifikasi
di repo ini (AGENTS §1.8). Strukturnya parameter; nilainya bukan.

| Hal | Siapa yang memutuskan | Menahan task |
| --- | --- | --- |
| Daftar status anggota (calon/aktif/nonaktif/keluar) dan syarat perpindahan | pemilik (AD/ART) | T-182, T-183 |
| Nominal & kadens **simpanan pokok** (sekali saat masuk? diulang bila keluar-lalu-masuk?) dan **simpanan wajib** | pemilik (AD/ART + RAT) | T-184 |
| Apakah tunggakan simpanan wajib memblokir pinjaman/penarikan | pemilik | T-184 |
| Akun COA untuk "SHU belum dibagi" dan jurnal penutup tahun | accounting owner | T-185 |
| Formula SHU: proporsi jasa simpanan vs jasa usaha, **basis** jasa usaha (bunga/margin dibayar? volume?), porsi cadangan & dana-dana | RAT (angka), accounting owner (perlakuan) + cek REG-101/UU 25/1992 | T-186 |
| Bentuk pembayaran SHU: tunai, dikreditkan ke simpanan, atau memotong tunggakan | pemilik (AD/ART) | T-187 |
| Perlakuan saat anggota keluar: simpanan pokok/wajib dikembalikan? dipotong pinjaman/tunggakan? | pemilik + akuntan | T-194 |
| Komponen, bobot, dan ambang skor kesehatan (REG-104) | compliance owner (Permenkop 9/2020 + Juknis 15/2021) | T-189 |

**Iuran anggota sengaja tidak masuk fase ini** (keputusan pemilik 3 Nov 2026). Survei praktiknya sudah
ada di `docs/compliance/iuran-practice-survey.md`, dan 4 pertanyaan akuntansinya masih terbuka di O-100.
Jangan menyelipkan iuran ke T-184: simpanan wajib (ekuitas) dan iuran (pendapatan) dua hal berbeda, dan
AD/ART yang beredar memakai kata "iuran" untuk keduanya.

## Urutan task yang diusulkan

Disusun supaya setiap baris bisa ditutup dengan bukti mesin, dan supaya bisa mulai walaupun angka SHU
belum ada: T-182…T-185 tidak bergantung pada satu angka pun.

| Usulan ID | Tujuan | Bergantung | Kriteria selesai (mesin) |
| --- | --- | --- | --- |
| T-182 | Skeleton modul `coop` + model anggota: relasi ke `party`, nomor anggota, status, tanggal masuk/keluar, cabang; migrasi expand-only; `MODULE.md` | pola T-161 | `archcheck` bersih; `migrate --check` bersih; `itcoop` dasar hijau; status sah dibaca dari parameter, bukan enum kode |
| T-183 | Siklus hidup keanggotaan: registrasi dari CIF, aktivasi, penonaktifan, keluar; event `MembershipChanged` lewat outbox; audit; izin `coop.member.*`; penolakan keluar bila pinjaman aktif (kebijakan = parameter) | T-182 | uji transisi sah/tidak sah; penolakan keluar berpinjaman 409; audit satu baris per perubahan; `itcoop` hijau |
| T-184 | Kewajiban & realisasi simpanan pokok/wajib **per anggota**, dibaca dari produk + transaksi `deposit` (bukan mesin penagihan baru): target, terbayar, tunggakan; laporan tunggakan | T-182, T-183 | Σ realisasi per anggota = saldo akun `301.1`/`301.2` pada fixture tetap; tunggakan cocok hitungan tangan; tidak ada tabel tagihan baru |
| T-185 | Tutup buku tahunan: task EOY `coop.year_close` di `daycloser` — jurnal penutup pendapatan/beban → "SHU belum dibagi"; akun & pemetaan dari parameter; idempoten per tahun buku | T-182, T-137 (pola task EOM) | `itdaycloser_coop`: trial balance seimbang sesudahnya; run kedua tidak menggandakan jurnal; tanggal buku di luar tahun ditolak |
| T-186 | Perhitungan & usulan SHU: alokasi per anggota (jasa simpanan & jasa usaha), potongan cadangan/dana-dana, event `SHUProposed`; seluruh persentase & basis dari parameter RAT | T-184, T-185 | Σ alokasi = SHU; sisa pembulatan jatuh ke pos yang ditentukan parameter; golden test vs fixture spreadsheet akunting; idempoten per tahun |
| T-187 | Distribusi SHU setelah keputusan RAT: maker-checker, posting ke kas/simpanan anggota, arsip keputusan RAT (nomor, tanggal, bukti) | T-186 | Δ GL = Σ distribusi; replay `Idempotency-Key` tidak menggandakan; distribusi ditolak tanpa persetujuan RAT |
| T-188 | Paket laporan RAT: posisi keuangan, laba-rugi, perubahan ekuitas, daftar anggota, SHU per anggota; cetak/ekspor lewat jalur cetak yang sudah ada | T-184, T-187 | angka cocok fixture tetap; halaman cetak teruji; tidak ada angka turunan yang dihitung ulang di web (server yang menghitung) |
| T-189 | Laporan rasio & aspek kesehatan (REG-104): komponen keuangan terukur (mis. permodalan, likuiditas, kualitas aset) + input manual aspek non-keuangan; bobot/ambang = parameter bertanda `NEEDS-COMPLIANCE-REVIEW` | T-188 | rasio cocok hitungan tangan pada fixture; ambang dari parameter; laporan menyatakan sendiri bahwa skor resmi LHPKK belum diklaim |
| T-190 | Permukaan API: rute, OpenAPI, izin, scoping cabang | T-183…T-188 | `./task openapi` hijau; contract test; 403 lintas cabang teruji |
| T-191 | UI operator: daftar/detail anggota, status & riwayat, tunggakan, layar SHU (usulan → distribusi), paket RAT | T-190, DESIGN v2 | axe `moderate` 2 tema × 2 locale; keyboard-only; baseline visual baru; pratinjau sebelum distribusi SHU |
| T-192 | Simulasi setahun penuh: anggota + simpanan wajib + pinjaman + tutup buku + SHU; benchmark EOY; laporan M5 | T-185…T-187 | `itdaycloser_sim` mencakup siklus tahunan anggota; bench EOY dengan 5.000 anggota + 50k pinjaman; `docs/milestones/M5-report.md` |
| T-193 | Paket pilot: data demo koperasi sintetis (anggota, simpanan, pinjaman, satu tahun buku), checklist UAT, runbook RAT | T-191, T-192 | data demo bisa dimuat ulang dari nol dengan satu perintah; checklist UAT punya bukti per butir; **satu-satunya kriteria non-mesin: tanda tangan UAT koperasi** |
| T-194 | Penyelesaian anggota keluar (pengembalian simpanan pokok/wajib, potong pinjaman/tunggakan) | T-183 + keputusan pemilik/akuntan | **BELUM BOLEH DIMULAI**: menunggu perlakuan ekuitas saat keluar. Bila diputuskan, jurnalnya wajib `HUMAN-REVIEW-REQUIRED` |

## Non-goals fase ini

- **Iuran anggota** (O-100) — ditunda pemilik; bukan bagian Fase 5.
- APU-PPT, STR/CTR, pajak, pelaporan regulator generik → Fase 6.
- BMPP (T-181) → Fase 6; butuh definisi operasional Modal Sendiri.
- Syariah (akad, nisbah, bagi hasil) → Fase 8.
- Multi-koperasi dalam satu deployment → di luar asumsi single-tenant (spec §26.1).
- Mesin penagihan/dunning untuk simpanan wajib: T-184 hanya **membaca** kewajiban dan realisasi.
  Bila kelak butuh penagihan otomatis, itu task tersendiri dengan keputusan kadens & sanksi.

## Risiko yang sudah terlihat

1. **"SHU" mudah dianggap laba bank.** Ia dibagi menurut jasa simpanan *dan* jasa usaha, bukan porsi
   kepemilikan saham; salah basis = salah bagi ke setiap anggota. Karena itu T-186 butuh fixture
   spreadsheet yang divalidasi akuntan, bukan hanya property test.
2. **Angka cadangan/dana-dana punya lantai regulasi** yang belum diverifikasi di repo (UU 25/1992
   Pasal 45 dan turunannya belum masuk `register-validation.md`). Sampai diverifikasi, semua porsi
   `NEEDS-COMPLIANCE-REVIEW` dan SHU dilarang dibagikan ke anggota nyata.
3. **Tutup buku tahunan menyentuh rumus yang tidak bisa dibuktikan mesin sendiri** (jurnal penutup).
   T-185 harus ditandai `HUMAN-REVIEW-REQUIRED` seperti T-138/T-167.
4. **Data anggota adalah data pribadi** (UU PDP, REG-002 deferred). Fase 5 menambah tabel orang;
   enkripsi field-level (D-048) dan masking harus ikut sejak T-182, bukan ditambal belakangan.
5. **RAT adalah acara, bukan laporan.** Kalau T-188 hanya menghasilkan PDF tanpa arsip keputusan
   (T-187), sistem tidak bisa membuktikan angka mana yang disahkan.

## Yang saya minta dari pemilik

1. Setujui atau koreksi urutan T-182…T-194 → saya ubah jadi baris `READY` di `BACKLOG.md`.
2. Jawab empat hal yang menahan T-184/T-185 lebih awal: status anggota, nominal & kadens simpanan
   pokok/wajib, akun penutup tahun, dan apakah tunggakan memblokir pinjaman.
3. Putuskan apakah T-186 boleh dikerjakan **strukturnya** sebelum angka RAT ada (pola yang sama
   dengan PPAP di Fase 4), atau menunggu angka.

Bila disetujui, saya mulai dari **T-182 + T-183** yang tidak bergantung pada satu angka pun.
