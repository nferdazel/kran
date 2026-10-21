# Draf matriks pemisahan tugas (SoD) — O-016

Tabel `platform.role_conflict` sudah ada dan dipakai `grantRole`/`authorize`; isinya **kosong**
karena pasangan yang dilarang adalah kebijakan institusi/compliance (bukan tebakan teknis).

Dokumen ini mengusulkan kandidat untuk di-review. **Jangan** mengisi tabel sebelum disetujui.

## Kandidat konflik (perlu keputusan)

| Peran A | Peran B | Alasan | Tingkat |
|---|---|---|---|
| `param_maker` | `param_checker` | satu orang tidak boleh mengajukan dan menyetujui nilai parameter yang sama (spec §10.2) | wajib |
| `platform_admin` | `param_checker`? | admin bisa memberi dirinya peran checker lalu menyetujui pengajuannya sendiri | perlu keputusan |
| pembuat produk (manage) | penyetuju produk (approve, T-086) | maker-checker katalog produk (D-099) | wajib saat T-086 |
| teller | otorisasi jurnal manual? | pemisahan pelaksana vs penyetuju koreksi | perlu keputusan |
| pembuat jurnal | pembalik jurnal | koreksi atas perbuatan sendiri | perlu keputusan |

Catatan: `platform_admin` saat ini memegang **seluruh** izin yang dikenal. Selama itu berlaku,
pemisahan peran lain bisa dinegosiasikan dengan memberi admin peran ganda; konflik yang menyertakan
`platform_admin` harus diputuskan eksplisit (mis. larang pemberian `param_maker`+`param_checker`
pada pengguna yang sama, termasuk lewat admin).

## Cara menerapkan setelah disetujui

```sql
-- contoh; isi hanya setelah keputusan tertulis
INSERT INTO platform.role_conflict (role_a, role_b, reason)
SELECT a.role_id, b.role_id, 'maker-checker parameter (spec §10.2)'
  FROM platform.role a, platform.role b
 WHERE a.code = 'param_maker' AND b.code = 'param_checker'
ON CONFLICT DO NOTHING;
```

Uji: `grantRole` harus menolak pemberian peran kedua; `authorize` harus menolak bila pengguna sudah
memegang pasangan terlarang. Tambahkan test di `itapi_roles` sebelum seed produksi.

**Status:** draf, `NEEDS-COMPLIANCE-REVIEW`. Belum ada baris yang di-seed.
