-- O-016 / D-113: pasangan SoD yang ditegakkan sekarang.
--
-- Satu-satunya pasangan yang disemai di repo: `param_maker` vs `param_checker`.
-- Alasannya bukan selera: `0008` sudah memberi kedua peran izin submit/approve yang saling
-- melengkapi, dan `param_value_no_self_approval_chk` hanya memblokir approver = maker pada satu
-- baris; tanpa baris ini satu orang tetap bisa memegang dua peran lalu menyetujui pengajuan orang
-- lain. Pasangan lain (termasuk yang menyertakan `platform_admin`) tetap butuh keputusan institusi
-- dan TIDAK disemai di sini.
--
-- Kanonik: role_code_a < role_code_b (CHECK di 0006).
INSERT INTO platform.role_conflict (role_code_a, role_code_b, reason_key)
VALUES ('param_checker', 'param_maker', 'sod.param.maker_checker')
ON CONFLICT (role_code_a, role_code_b) DO NOTHING;
