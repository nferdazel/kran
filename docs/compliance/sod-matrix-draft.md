# Draf matriks pemisahan tugas (SoD) — O-016

Tabel `platform.role_conflict` sudah ada dan dipakai `grantRole`/`authorize`. Enam pasangan sudah
tersemai: `param_maker`/`param_checker` (`0020`, D-113) dan `product_maker`/`product_checker`,
`cash_admin`/`ledger_admin`, `ledger_admin`/`ops_admin`, `ledger_admin`/`teller`,
`cash_admin`/`teller` (`0032`, D-131). Pasangan **lain** tetap kebijakan institusi/compliance
(bukan tebakan teknis) dan belum diisi.

Dokumen ini mencatat kandidat yang masih perlu keputusan. **Jangan** mengisi tabel sebelum disetujui.

## Kandidat konflik (perlu keputusan)

| Peran A | Peran B | Alasan | Tingkat |
|---|---|---|---|
| `param_maker` | `param_checker` | satu orang tidak boleh mengajukan dan menyetujui nilai parameter yang sama (spec §10.2) | **tersemai** (`0020`, D-113) |
| `platform_admin` | `param_checker`? | admin bisa memberi dirinya peran checker lalu menyetujui pengajuannya sendiri | **tidak dipasangkan**: `platform_admin` tinggal break-glass (D-131) |
| `product_maker` | `product_checker` | maker-checker katalog produk (D-099) | **tersemai** (`0032`, D-131) |
| teller | otorisasi jurnal manual? | pemisahan pelaksana vs penyetuju koreksi | perlu keputusan |
| pembuat jurnal | pembalik jurnal | koreksi atas perbuatan sendiri | perlu keputusan |

Catatan: `platform_admin` masih memegang **seluruh** izin yang dikenal, tetapi sejak D-131 berperan
**break-glass** (bukan harian) dan sengaja **tidak** dipasangkan konflik — memasangkannya akan
melumpuhkan jalur darurat itu sendiri. Pemisahan ditegakkan lewat peran sempit (`ops_admin`,
`ledger_admin`, `cash_admin`, `product_maker`/`product_checker`). Bila kelak pasangan lain
diputuskan, terapkan seperti contoh berikut.

## Cara menerapkan setelah disetujui

```sql
-- contoh; isi hanya setelah keputusan tertulis (kolom mengikuti 0006)
INSERT INTO platform.role_conflict (role_code_a, role_code_b, reason_key)
VALUES ('param_checker', 'param_maker', 'sod.param.maker_checker')
ON CONFLICT (role_code_a, role_code_b) DO NOTHING;
```

Uji: `grantRole` harus menolak pemberian peran kedua; `authorize` harus menolak bila pengguna sudah
memegang pasangan terlarang — diuji `itauth`/`itapi_roles`.

**Status:** draf, `NEEDS-COMPLIANCE-REVIEW`. Pasangan `param_maker`/`param_checker` dan lima pasangan
peran sempit sudah tersemai (D-113/D-131); baris sisanya menunggu keputusan.
