# Exit criteria - a11y & keyboard gate (design system v2)

Owner: Sari (QA). Dijalankan untuk setiap PR yang memigrasikan layar, dan wajib hijau penuh
sebelum fase ditutup. Dokumen ini menulis **cara gagal**, bukan cara lulus: kalau sebuah
kriteria tidak bisa dibuktikan, hasilnya FAIL atau BLOCKED, bukan PASS.

Perintah:

```bash
node tools/qa/a11y/a11y-matrix.mjs   --config app --label gate-<ticket>
node tools/qa/a11y/keyboard-flows.mjs --config keyboard-app --label gate-<ticket>
```

Exit code: `0` semua PASS, `1` ada FAIL, `2` ada BLOCKED (tetap **tidak hijau**).

---

## 1. Matriks axe

**Cakupan wajib: 24 K-ID x 2 tema x 2 lebar = 96 kombinasi.**
Ditambah 3 varian mode teller (K-01b setor, K-01c tarik, K-01d transfer) = **108 kombinasi**
kalau mode teller dirender sebagai layar terpisah.

Aturan: axe tag `wcag2a, wcag2aa, wcag21a, wcag21aa, wcag22aa`. Ambang gate: **0 violation
dengan impact critical, serious, atau moderate**. `minor` dicatat di laporan dan tidak
memblokir, tapi harus turun atau tetap - tidak boleh naik tanpa alasan tertulis di ticket.

| K-ID | Rute | Pola |
|---|---|---|
| K-01 | `/app/teller` | Transaction shell |
| K-02 | `/app/vault` | List + approval |
| K-03 | `/app/close` | Report + confirm |
| K-04 | `/app/ledger` | List + totals |
| K-05 | `/app/ledger/admin` | List + editor |
| K-06 | `/app/members` | List |
| K-07 | `/app/members/new` | Form |
| K-08 | `/app/members/{memberId}` | Detail |
| K-09 | `/app/members/{memberId}/exit` | Form + confirm |
| K-10 | `/app/savings/obligations` | List |
| K-11 | `/app/loans` | List |
| K-12 | `/app/loans/new` | Form |
| K-13 | `/app/loans/approvals` | List + approval |
| K-14 | `/app/loans/{loanId}` | Detail + payment |
| K-15 | `/app/loans/arrears` | List |
| K-16 | `/app/reports` | Report |
| K-17 | `/app/audit` | List |
| K-18 | `/app/users` | List |
| K-19 | `/app/params` | List + form |
| K-20 | `/app/products` | List + form dialog |
| K-21 | `/app/password` | Form |
| K-22 | `/login` | Auth (di luar shell) |
| K-23 | `/app/print/slip/{transactionId}` | Report A5 |
| K-24 | `/app/print/statement/{accountId}` | Report A4 |

### Kriteria gagal (semua harus bisa terjadi)

1. **Halaman tidak termuat** - HTTP >= 400, `page.goto` error, atau timeout. FAIL.
2. **Layar tidak benar-benar dirender** - selector jangkar layar berjumlah kurang dari
   minimum yang diminta (mis. tabel tanpa baris). FAIL.
3. **Tema tidak berpindah** - `html[data-theme]` atau atribut pembungkus tidak sama dengan
   tema yang diminta. FAIL, bukan "dianggap terang".
4. **Lebar tidak berpindah** - untuk target yang memakai kontrol lebar, atribut lebar tidak
   sama dengan yang diminta; untuk target viewport, lebar viewport != 1440/360. FAIL.
5. **Redirect ke login** tanpa sesi - BLOCKED dengan sebab tertulis. Tidak hijau.
6. **Fixture kosong** (`{memberId}`, `{loanId}`) - BLOCKED, bukan PASS dengan halaman 404.
7. **axe error / tidak bisa inject** - FAIL. Axe yang tidak jalan bukan lulus.
8. **Nol node dalam cakupan** - FAIL. Hasil "0 violation" dari area kosong tidak dihitung.
9. **Violation moderate+** - FAIL, dan laporan wajib memuat id rule + selector node pertama.
10. **Mengubah scope agar hijau** (mis. mengecualikan bagian layar) - pelanggaran gate;
    pengecualian butuh `D-xxx` dan persetujuan pemilik.

Cakupan per layar dibatasi ke region layar itu sendiri (`.stage` / `main`), supaya chrome
dokumen tidak bisa menutupi hasil. Violation di luar cakupan tetap dicatat terpisah, tidak
dibuang.

## 2. Keyboard - 5 alur wajib

Tidak ada yang boleh PASS dari klaim kode; tiap langkah dijalankan dengan input keyboard
sungguhan dan diverifikasi ke `document.activeElement`.

| # | Alur | K | Lulus bila |
|---|---|---|---|
| 1 | Setor teller | K-01 | F2 memindahkan fokus ke pencarian; hasil bisa dipilih dengan Enter; panel review muncul; tombol Setor dicapai dengan Tab, punya cincin fokus >= 2 px, Enter memposting dan fokus berpindah ke konfirmasi (bukan jatuh ke body) |
| 2 | Approve kas besar | K-02 | Baris gerakan tertunda bisa dibuka dengan Enter; ApprovalPanel tampil; tombol approve fokus-visible; tidak ada aksi yang bisa dieksekusi tanpa nama tombol yang benar |
| 3 | Tutup kas / tutup buku | K-03 | Aksi tutup dicapai dan dipicu dari keyboard; dialog konfirmasi menahan fokus; Escape menutup dan mengembalikan fokus ke pemicu |
| 4 | Drawer detail jurnal | K-04 | Enter di baris membuka drawer `role=dialog`; fokus masuk drawer; Tab tidak keluar drawer; Escape menutup dan mengembalikan fokus ke baris |
| 5 | Sidebar < 1024 px | T-285 shell | Tombol menu `aria-expanded=false` -> `true`; fokus masuk panel; Tab tidak keluar panel; Escape menutup dan fokus kembali ke tombol menu |

Kriteria gagal:

1. Fokus berpindah ke elemen yang salah - FAIL, laporan menyebut elemen yang didapat.
2. Cincin fokus tidak terlihat pada elemen yang difokus (`minWidth 2` px di app 1:1) - FAIL.
3. Fokus keluar dari panel drawer/sidebar selama `maxTabs` - FAIL (aria-modal yang tidak jujur).
4. Escape tidak menutup, atau menutup tanpa mengembalikan fokus - FAIL.
5. `aria-expanded`/`aria-current`/`role` tidak berubah sesuai state - FAIL.
6. Selector belum ditulis (`TODO:` di config) - BLOCKED, tidak hijau.
7. Butuh sesi login tapi belum ada - BLOCKED, tidak hijau.
8. Alur dijalankan di mockup lalu dilaporkan sebagai app - pelanggaran gate; mockup hanya
   baseline, bukan bukti app.

## 3. Baseline yang sudah ada

Lihat `.local/qa/results/baseline-mockup.md` dan `keyboard-mockup.md`. Ringkas:

- 12 kombinasi mockup (buku besar, drawer terbuka, login x 2 tema x 2 lebar):
  **0 violation gate, 0 minor**.
- Di luar cakupan layar: 1 `color-contrast` serious di `h2 > code` (judul catatan mockup).
  Bukan layar produk, tapi tetap dicatat.
- Keyboard: 2 PASS, 2 FAIL - lihat bagian 4.

## 4. Temuan baseline (mockup, bukan app)

1. **Fokus tidak kembali setelah drawer ditutup** - `Escape` menutup drawer, tapi fokus jatuh
   ke `body`. Ini wajib benar di T-290, dan flow 4 sudah menguji titik ini.
2. **Drawer mockup tidak menahan fokus** - `aria-modal="true"` tapi Tab keluar ke chrome
   dokumen. `aria-modal` yang tidak jujur lebih buruk daripada tanpa drawer. Wajib trap di
   T-290.

Keduanya tidak boleh dianggap bug app (drawer app belum ada), tapi juga tidak boleh hilang
dari laporan: flow yang sama dipakai di gate app, jadi kalau T-290 lupa trap, gate-nya merah.

## 5. Bukti yang harus ditempel di ticket

- Perintah + exit code untuk kedua runner.
- Path laporan `results/<label>.md` dan jumlah combo PASS/FAIL/BLOCKED.
- Daftar violation (id + selector) kalau ada, atau baris "0 violation gate" per kombinasi.
- Untuk flow keyboard: status per langkah, bukan ringkasan.

## 6. Yang belum bisa diverifikasi sekarang

- App Svelte belum punya sesi + database di mesin ini; `/app/*` redirect ke `/login`, jadi
  matriks app akan BLOCKED sampai fixture sesi disiapkan.
- State (`loading`, `empty`, `no-match`, `error`, `denied`) belum digambar; axe pada state
  hanya bisa dijalankan setelah T-292.
- 360 px di mockup adalah container 360 px di dalam viewport 1440 (mockup memakai CSS zoom),
  jadi baseline ini tidak membuktikan reflow pada viewport 360 sungguhan. Gate app memakai
  viewport asli dan itu yang mengikat.
