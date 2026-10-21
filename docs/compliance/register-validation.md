# Validasi register regulasi (§4) — O-001

Dokumen ini adalah daftar kerja untuk **compliance owner**. Kode/seed tidak boleh memakai nilai
regulasi final sebelum baris terkait ditandai tervalidasi di sini.

## Aturan penandaan

- Nilai/pasal yang belum diverifikasi **wajib** ditandai `NEEDS-COMPLIANCE-REVIEW` di kode/seed/docs.
- Seed base hanya berisi nilai **teknis/kebijakan internal/komersial konservatif**; nilai regulasi
  (rate, nisbah, pajak, PPAP, LPS) **tidak** disemai (D-095).
- Perubahan status baris di sini harus disertai sumber resmi (nomor, pasal, tanggal akses).

## Daftar V?/V! yang perlu diverifikasi

| ID | Perlu diverifikasi | Dipakai di | Status |
|---|---|---|---|
| REG-001 | P2SK: pengaturan/pengawasan koperasi & BPR, masa transisi | lingkup produk, laporan | `NEEDS-COMPLIANCE-REVIEW` |
| REG-002 | PDP: dasar pemrosesan, retensi, notifikasi kebocoran (3×24 jam), DPO | field encryption, audit, retensi | `NEEDS-COMPLIANCE-REVIEW` |
| REG-003 | PP-TPPU: CDD, CTR/STR, retensi dokumen | KYC, pelaporan | `NEEDS-COMPLIANCE-REVIEW` |
| REG-004 | POJK APU-PPT (nomor/versi), PEP, screening DTTOT/DPPSPM | KYC, risk rating | `NEEDS-COMPLIANCE-REVIEW` |
| REG-005 | UU ITE/PP 71/2019: dokumen & tanda tangan elektronik | bukti transaksi | `NEEDS-COMPLIANCE-REVIEW` |
| REG-006 | POJK pelindungan konsumen: disclosure, SLA pengaduan | produk, UI | `NEEDS-COMPLIANCE-REVIEW` |
| REG-007 | Retensi dokumen keuangan (10 tahun?) | parameter retensi/arsip | `NEEDS-COMPLIANCE-REVIEW` |
| REG-008 | Pajak: PPh final bunga/bagi hasil, PPN fee, bukti potong, AEOI | parameter pajak, laporan | `NEEDS-COMPLIANCE-REVIEW` |
| REG-009 | LPS: penjaminan, tingkat bunga penjaminan, transisi koperasi | parameter rate, flag simpanan | `NEEDS-COMPLIANCE-REVIEW` |
| REG-010 | Dukcapil: bentuk verifikasi NIK/e-KTP | adapter identitas | `NEEDS-COMPLIANCE-REVIEW` |
| REG-011 | SAK EP/PSAK syariah: COA, pengakuan margin/bagi hasil, akun kontra | COA, posting rule, laporan | `NEEDS-COMPLIANCE-REVIEW` |

## Checklist sign-off

- [ ] Setiap baris di atas diverifikasi ke sumber resmi (nomor + pasal + tanggal akses).
- [ ] Nilai yang akan disemai ditulis di `packs/base/seed/` dengan komentar sumber dan tanggal.
- [ ] Nilai yang belum final tetap kosong; produk yang membutuhkannya gagal-cepat (bukan default).
- [ ] `docs/OPEN_ITEMS.md` O-001 diperbarui; `NEEDS-COMPLIANCE-REVIEW` dihapus hanya untuk baris yang
      sudah ditandatangani.

**Status:** belum ada baris yang divalidasi. Semua nilai regulasi tetap tertunda.
