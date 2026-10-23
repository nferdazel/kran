# Runbook — vault kas produksi (satu kali)

Dipakai saat `teller.vault` belum punya baris untuk cabang operasional. Tanpa baris vault, sesi kas
menolak dibuka dengan `vault_not_configured` (fail-closed) dan `POST /teller/vault/topups` 404.

Batas yang disepakati: tanpa jurnal GL (O-097), tanpa maker-checker/batas nominal (O-098/O-099).
Penyesuaian saldo turun belum punya API; koreksi hanya lewat SQL oleh pemilik/ops.

## Prasyarat

- `branch_id` pilot sudah ditetapkan. Belum ada tabel master cabang (O-101); sampai itu ada, semua
  rekening dan sesi teller pilot **harus memakai UUID yang sama** dengan vault.
- Nominal float disetujui pemilik secara eksplisit. Jangan mengarang nominal.

## Langkah (dijalankan 23 Okt 2026 untuk pilot)

1. Jalankan SQL sebagai role owner (bukan role runtime API), di host DB:

   ```sql
   INSERT INTO teller.vault (branch_id, balance)
   VALUES ('<branch-uuid>', '<nominal>')
   ON CONFLICT (branch_id) DO NOTHING;

   SELECT branch_id, balance FROM teller.vault ORDER BY branch_id;
   ```

2. Verifikasi lewat API dengan sesi operator yang memegang `teller.vault.read`:

   ```
   GET /api/v1/teller/vault?branchId=<branch-uuid>   → 200 {branchId, balance}
   ```

3. Catat branch UUID + nominal + waktu eksekusi di `docs/PROGRESS.md`. Jangan mencatat kredensial.

## Bukti eksekusi produksi (23 Okt 2026)

- Cabang pilot: `b0000000-0000-4000-8000-000000000001` (placeholder sampai master cabang ada).
- Float awal: `10000000.0000` (Rp10.000.000), disetujui pemilik.
- Hasil: `INSERT 0 1`; `SELECT` → satu baris dengan saldo tersebut.
- Konsekuensi: sesi kas pilot bisa dibuka; saldo ini **tidak** tercermin di neraca GL (O-097).

## Rollback / koreksi

- Turunkan saldo hanya lewat SQL eksplisit dengan alasan tertulis (tidak ada API debit vault), lalu
  rekonsiliasi dengan kas fisik dan `platform.audit_log`.
- Menghapus baris vault akan mematikan sesi kas (fail-closed) — jangan sebagai "rollback" deploy.
