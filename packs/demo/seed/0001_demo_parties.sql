-- Data demo untuk pilot (SINTETIS — bukan data anggota nyata).
--
-- Kenapa tidak masuk `packs/*/seed/`: seed produksi hanya memuat `packs/*/generated/*.sql`
-- (main.nim), jadi berkas ini tidak akan pernah ikut deploy. Terapkan manual, lihat
-- `docs/runbooks/demo-data.md`.
--
-- Isi: 12 party (11 orang + 1 koperasi) + profil KYC.
--
-- Riwayat `party.risk_rating` sengaja TIDAK diisi: tabel itu append-only (trigger menolak DELETE),
-- jadi baris demo akan permanen di database. Untuk demo, rating berjalan di `kyc_profile` cukup.
--
-- Sengaja TIDAK ada `party.identity_doc`: `number_enc` harus ciphertext field-crypto dengan kunci
-- KEK, jadi baris buatan SQL akan gagal didekripsi. Membuat identitas demo yang benar butuh jalur
-- aplikasi (bukan INSERT mentah).
--
-- Penanda untuk pembersihan: CIF 9000001..9000012 (sequence asli mulai dari 1, jadi tidak bentrok
-- dalam waktu lama) dan `branch_id` demo tetap di bawah.

INSERT INTO party.party (party_id, cif, kind, display_name, status, branch_id, created_by, updated_by)
SELECT md5('demo:' || d.cif)::uuid, d.cif, d.kind, d.display_name, 'ACTIVE',
       '00000000-0000-4000-8000-000000000001'::uuid, u.uid, u.uid
  FROM (VALUES
    ('9000001', 'PERSON', 'Budi Santoso'),
    ('9000002', 'PERSON', 'Siti Aminah'),
    ('9000003', 'PERSON', 'Ahmad Fauzi'),
    ('9000004', 'PERSON', 'Dewi Lestari'),
    ('9000005', 'PERSON', 'Rudi Hartono'),
    ('9000006', 'PERSON', 'Nur Aisyah'),
    ('9000007', 'PERSON', 'Agus Setiawan'),
    ('9000008', 'PERSON', 'Rina Wulandari'),
    ('9000009', 'PERSON', 'Joko Purnomo'),
    ('9000010', 'PERSON', 'Sri Rahayu'),
    ('9000011', 'PERSON', 'Hendra Gunawan'),
    ('9000012', 'ORG',    'Koperasi Serba Usaha Maju Bersama')
  ) AS d(cif, kind, display_name)
  CROSS JOIN (SELECT coalesce(
    (SELECT user_id FROM platform.app_user WHERE username = 'admin'),
    (SELECT user_id FROM platform.app_user ORDER BY created_at LIMIT 1)) AS uid) u
ON CONFLICT (cif) DO NOTHING;

-- Profil KYC: status, rating, jadwal re-KYC (bulan mengikuti parameter party.kyc.review_months).
INSERT INTO party.kyc_profile
  (party_id, status, risk_level, risk_assessed_at, next_review_due, created_by, updated_by)
SELECT p.party_id, d.kyc_status, d.risk_level,
       now() - (d.rated_days_ago || ' days')::interval,
       CASE WHEN d.kyc_status = 'VERIFIED'
            THEN (current_date + (d.review_months || ' months')::interval)::date
            ELSE NULL END,
       p.created_by, p.created_by
  FROM (VALUES
    ('9000001', 'VERIFIED', 'LOW',    36, 210),
    ('9000002', 'VERIFIED', 'LOW',    36, 180),
    ('9000003', 'VERIFIED', 'MEDIUM', 12, 120),
    ('9000004', 'VERIFIED', 'LOW',    36, 300),
    ('9000005', 'VERIFIED', 'HIGH',    6,  40),
    ('9000006', 'PENDING',  'LOW',     0,  10),
    ('9000007', 'VERIFIED', 'LOW',    36, 150),
    ('9000008', 'VERIFIED', 'MEDIUM', 12,  95),
    ('9000009', 'PENDING',  'LOW',     0,   5),
    ('9000010', 'VERIFIED', 'LOW',    36, 250),
    ('9000011', 'REJECTED', 'HIGH',    0,  20),
    ('9000012', 'VERIFIED', 'MEDIUM', 12, 100)
  ) AS d(cif, kyc_status, risk_level, review_months, rated_days_ago)
  JOIN party.party p ON p.cif = d.cif
ON CONFLICT (party_id) DO NOTHING;
