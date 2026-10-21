# Data demo (sintetis) untuk pilot

Berkas: `packs/demo/seed/0001_demo_parties.sql`.

**Tidak ikut deploy.** Seed produksi hanya memuat `packs/*/generated/*.sql`, jadi berkas ini harus
diterapkan manual dan boleh dihapus kapan saja.

## Terapkan

```bash
ssh sachiel@43.133.148.191
podman exec -i qouver-postgres psql -U qouver -d kran \
  < /srv/qouver/apps/kran/monorepo/packs/demo/seed/0001_demo_parties.sql
```

Idempoten: `party_id`/`rating_id` deterministik dari CIF, `ON CONFLICT DO NOTHING`.

## Isi

12 party (11 orang + 1 koperasi), CIF `9000001`–`9000012`, `branch_id` demo tetap
`00000000-0000-4000-8000-000000000001`, plus profil KYC (VERIFIED/PENDING/REJECTED, risiko
LOW/MEDIUM/HIGH). Riwayat `risk_rating` tidak diisi karena append-only (tidak bisa dihapus).

Tidak ada `party.identity_doc`: nomor identitas wajib ciphertext field-crypto dengan kunci KEK,
jadi baris buatan SQL tidak bisa didekripsi aplikasi. Kalau demo butuh NIK tersamar, buat lewat
jalur aplikasi atau tambahkan perintah `ctl` khusus.

## Bersihkan

```sql
BEGIN;
DELETE FROM party.kyc_profile  WHERE party_id IN (SELECT party_id FROM party.party WHERE cif LIKE '90000%');
DELETE FROM party.identity_doc WHERE party_id IN (SELECT party_id FROM party.party WHERE cif LIKE '90000%');
DELETE FROM party.party         WHERE cif LIKE '90000%';
COMMIT;
```

Urutan penting: `kyc_profile`/`identity_doc` memakai `ON DELETE RESTRICT`, jadi child dulu.
Karena `risk_rating` tidak diisi, tidak ada trigger append-only yang menghalangi pembersihan.
