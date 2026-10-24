-- Pemisahan kas teller (laci) vs vault lewat sub-akun clearing (T-118, memo
-- `docs/proposals/t-118-operator-governance.md` §5 opsi A yang disetujui pemilik).
--
-- NEEDS-COMPLIANCE-REVIEW (REG-011, spec §4 `V!`): kode `101.1`/`101.2`/`101.9` adalah **usulan
-- struktur pilot** dari memo T-118, bukan kutipan SAK EP/PSAK. `101 KAS` tetap **induk** dan menjadi
-- non-postable; kode/klasifikasi final menunggu keputusan compliance/accounting owner.
--
-- Konteks D-130: master cabang + penomoran rekening ber-kode cabang sudah ada, tetapi jurnal
-- buka/tutup sesi, top-up vault, dan sweep variance **belum** berjurnal (O-097). Migrasi ini hanya
-- menyiapkan akun dan memindahkan arah posting kas di konter; jurnal sesi teller adalah task lanjutan.
--
-- Ditaruh di migrasi (bukan `packs/*/seed/`) karena seed pack hanya diterapkan dengan `--dev`;
-- produksi menerima COA lewat jalur migrasi (lihat O-066 dan `docs/tasks/T-072.md`).
--
-- Idempoten: `ON CONFLICT (code) DO NOTHING` untuk akun baru; `postable=false` dan pemindahan
-- `posting_rule_line` idempoten secara alami (jalankan ulang = 0 baris atau nilai sama).
--
-- Jurnal historis tetap memakai `101` — `ledger.journal_line` **tidak** disentuh (immutable).

INSERT INTO ledger.coa_account
  (account_id, code, name, account_type, normal_side, postable, status, created_by, updated_by)
VALUES
  (md5('ledger.coa|101.1')::uuid, '101.1', 'KAS DI VAULT',  'ASSET', 'DEBIT', true, 'ACTIVE', '00000000-0000-0000-0000-0000000000a1', '00000000-0000-0000-0000-0000000000a1'),
  (md5('ledger.coa|101.2')::uuid, '101.2', 'KAS DI TELLER', 'ASSET', 'DEBIT', true, 'ACTIVE', '00000000-0000-0000-0000-0000000000a1', '00000000-0000-0000-0000-0000000000a1'),
  (md5('ledger.coa|101.9')::uuid, '101.9', 'SELISIH KAS',   'ASSET', 'DEBIT', true, 'ACTIVE', '00000000-0000-0000-0000-0000000000a1', '00000000-0000-0000-0000-0000000000a1')
ON CONFLICT (code) DO NOTHING;

-- `101 KAS` menjadi akun induk non-postable, sejalan dengan `1`/`2`/`3`/`4`/`5`: yang boleh
-- diposting hanya sub-akun (di sini `101.1`/`101.2`/`101.9`).
UPDATE ledger.coa_account SET postable = false WHERE code = '101';

-- Kas di konter sekarang diposting ke `101.2 KAS DI TELLER` supaya laci terpisah dari vault di
-- neraca. Mencakup 5 baris rule: `DepositPosted`/`FeeCharged` (0005), `DepositWithdrawn` (0012),
-- dan `DepositPosted` POKOK/WAJIB (0014).
UPDATE ledger.posting_rule_line SET gl_account = '101.2' WHERE gl_account = '101';
