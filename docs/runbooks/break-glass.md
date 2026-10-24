# Runbook — break-glass `platform_admin` (K-3, D-134)

`platform_admin` adalah akun **darurat**, bukan akun kerja harian. Halaman ini prosedur wajib
setiap kali akun itu dipakai. Angka/format di sini adalah keputusan pemilik (D-134), bukan kutipan
regulasi; butir yang menyentuh kewajiban hukum ditandai `NEEDS-COMPLIANCE-REVIEW`.

## Susunan minimum

| Akun | Peran | Tidak boleh juga memegang |
|---|---|---|
| O1 | `ops_admin` (pengaju top-up, administrasi pengguna/anggota) | `ledger_admin` |
| O2 | `cash_admin` (penyetuju top-up, penyediaan kas) | `ledger_admin`, `teller` |
| O3 | `teller` (kas laci) | `cash_admin`, `ledger_admin` |
| O4 (target) | `ledger_admin` (pembukuan, periode, COA, pembalik) | `cash_admin`, `ops_admin`, `teller` |
| BG | `platform_admin` — **tersegel**, dipegang pengurus | — |

Minimum **3 operator harian**; bila `cash_admin` menempel ke O1, setiap top-up rutin butuh BG
sebagai penyetuju, sehingga SoD jalur kas praktis hilang — terima hanya sebagai keadaan sementara.

## Kapan BG boleh dipakai

1. Menjadi **akun kedua** pada operasi ganda (maker ≠ checker) saat pembanding manusia tidak ada
   (cuti, berhenti, force majeure). Pakai akun harian sebagai maker, BG sebagai checker — dua
   `user_id` berbeda, jadi CHECK `vault_topup_self_approval_chk` tetap terpenuhi.
2. Perbaikan konfigurasi yang tidak punya jalur peran lain.

Tidak sah: memakai BG untuk melewati kontrol struktural (self-approval objek yang sama,
mencabut pengelola terakhir, mengubah jurnal historis).

## Wajib setiap pemakaian

1. **Audit sistem** (otomatis): `platform.audit_log` mencatat aksi, aktor, dan alasan singkat.
2. **Buku Break-glass** (berkas digital/buku fisik): waktu (WIB), akun harian (maker), akun BG
   (checker), operasi, `request_id`/`journal_id`, alasan, penanda tangan, inisial pengurus penelaah.
3. **Laporan H+1** ke pengurus (tertulis, ditandatangani).
4. **Ambang frekuensi**: lebih dari **3 pemakaian/bulan** butuh persetujuan pengurus lebih dulu.

## Cuti & berhenti

- Cuti ≤5 hari kerja: tidak ada perubahan peran; bila perlu operasi ganda, pakai BG + buku + laporan.
- Cuti >5 hari kerja atau berhenti, dalam **1 hari kerja**:
  1. Pastikan pengganti **sudah** memegang `platform.user.manage` (`assign-role` `ops_admin`),
     kalau tidak `disable-user` ditolak `last_admin`.
  2. `kran-api --role=ctl disable-user --username=<orang>` (mencabut semua sesi).
  3. Pindahkan peran esensial ke pengganti (`assign-role`); pasangan SoD yang lahir dari
     penugasan itu akan ditolak `sod_conflict` — itu benar, bukan bug.
  4. Jangan menyerahkan kata sandi; buat akun baru dengan kata sandi baru.

## Bukti top-up vault (K-4)

Format `note` pengajuan: `[JENIS SUMBER] <jenis bukti> <nomor referensi> | <tujuan>`.
Contoh: `[BANK] slip setoran 2026-10-24/BCA/123456 | setoran modal kas cabang`.

- Fisik asli: Berkas Bukti Kas cabang (per bulan). Salinan digital: folder bukti institusi (di luar
  DB). DB tidak menyimpan berkas; `request_id` = nomor dokumen.
- Retensi fisik: **10 tahun** — `NEEDS-COMPLIANCE-REVIEW` (REG-007 belum terverifikasi compliance).
  Data DB/audit/jurnal disimpan permanen.
- Checker menolak bila: nominal beda dengan bukti, akun sumber salah, `note` tanpa nomor referensi,
  cabang salah, pengaju orang yang sama, atau periode tanggal bisnis tidak OPEN.
