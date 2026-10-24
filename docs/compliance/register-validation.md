# Validasi register regulasi (§4) — O-001

Dokumen kerja untuk **compliance owner**. Kode/seed tidak boleh memakai nilai regulasi final
sebelum baris terkait ditandai tervalidasi di sini.

## Status per 21 Okt 2026

Klasifikasi **live vs deferred** di bawah berasal dari penelusuran pembaca parameter di kode
(bukan tebakan): item "live" punya konsumen di jalur pilot, item "deferred" tidak dibaca kode mana
pun sehingga tidak butuh nilai sekarang.

### Live (dipakai kode; nilainya sudah disemai, tetapi masih `NEEDS-COMPLIANCE-REVIEW`)

| ID | Parameter yang dibaca | Konsumen | Status |
|---|---|---|---|
| REG-003/004 | `party.kyc.risk_levels`, `party.kyc.default_risk_level`, `party.kyc.review_months` | `handlers_kyc.nim` (onboarding/re-KYC) | `NEEDS-COMPLIANCE-REVIEW` |
| REG-010 | `party.identity.doc_types`, `party.identity.doc_lengths` | `handlers_kyc.nim` (validasi identitas) | `NEEDS-COMPLIANCE-REVIEW` |
| REG-011 | `ledger.coa.code_pattern` | teknis (pola kode COA), bukan kebijakan akuntansi | `NEEDS-COMPLIANCE-REVIEW` |

Pilot boleh berjalan dengan nilai ini, tetapi **jangan diklaim sesuai regulasi** sampai
ditandatangani.

### Deferred (tidak ada pembaca di kode; nilai tidak disemai)

| ID | Alasan fungsional |
|---|---|
| REG-203/204 (PPAP/kolektibilitas) | modul `lending` belum ada; key hanya muncul di komentar contoh |
| REG-008 (pajak) | modul `tax` belum ada |
| REG-009 (LPS) | belum ada konsumen rate/flag penjaminan |
| REG-305 (bagi hasil syariah) | modul `sharia` belum ada |
| REG-005/006/007 (e-sign, disclosure, retensi) | tidak ada parameter pembaca; retensi arsip belum diimplementasi |

Tandai deferred di `docs/OPEN_ITEMS.md`; jangan isi nilainya "supaya ada".

## Risiko yang tersisa (dari SME compliance)

D-095 (tidak menyemai nilai regulasi) tetap benar dan gagal-cepat (`ParamNotFound`), bukan
nilai-salah-diam-diam. Risiko praktisnya: `platform.param_value` tidak menyimpan provenance review,
jadi setelah operator mengisi angka lewat maker-checker, angka tebakan tidak bisa dibedakan dari
yang sudah divalidasi.

**Mitigasi wajib:** `reason` pada pengajuan parameter harus memuat nomor sumber + tanggal akses,
atau nilai tetap ditandai `NEEDS-COMPLIANCE-REVIEW` di dokumentasi produk. Perbaikan skema
(kolom provenance) dicatat sebagai item Fase 2, bukan diubah diam-diam sekarang.

## Checklist sign-off

- [ ] Baris **live** diverifikasi ke sumber resmi (nomor + pasal + tanggal akses); alasan
      pengajuan parameter memuat sumber.
- [ ] Baris **deferred** disetujui tetap kosong sampai modulnya ada.
- [ ] `NEEDS-COMPLIANCE-REVIEW` dihapus hanya untuk baris yang sudah ditandatangani.

## Status: jalur 1 (D-114)

Pemilik menerima nilai default di atas **untuk pilot internal** — bukan klaim sesuai regulasi.
Penanda `NEEDS-COMPLIANCE-REVIEW` sengaja dipertahankan.

**Gate go-live komersial:** sebelum anggota nyata pertama atau klien BPR/koperasi pertama, nilai
pada scope institusi klien itu wajib divalidasi compliance klien/konsultan; `reason` pengajuan
parameter memuat nomor aturan + tanggal akses; penanda dicabut per institusi, bukan global.
