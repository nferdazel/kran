-- 0011: verifikasi rantai audit mengikuti `prev_hash`, bukan urutan `seq` (O-038, T-052).
--
-- Sebab: `seq` dialokasikan identity **sebelum** BEFORE-trigger `audit_log_chain_trg` mengambil
-- advisory lock. Bila dua transaksi bersisipan di jendela itu, baris ber-`seq` lebih besar bisa commit
-- lebih dulu, dan baris berikutnya merantai ke hash **baris itu** — rantainya tetap linear (setiap
-- baris menunjuk tepat satu pendahulu), hanya urutannya tidak lagi mengikuti `seq`. Pola lama
-- `lag(hash) OVER (ORDER BY seq)` karena itu melaporkan `link_ok=false` pada rantai yang utuh;
-- direproduksi deterministik di DB dev 17 Okt 2026 (seq 84 menunjuk hash seq 85, dan 85/85 baris
-- tercapai dengan mengikuti `prev_hash` dari genesis).
--
-- Aturan baru: `link_ok` = baris ini menunjuk tepat satu pendahulu yang ada, dan pendahulu itu tidak
-- dipakai baris lain:
--   (1) `prev_hash` = sentinel genesis (`repeat('0',64)`) atau ada baris lain ber-`hash` sama; dan
--   (2) tidak ada baris lain ber-`prev_hash` sama.
-- Syarat (2) mempertahankan deteksi yang dimiliki pola lama (cabang = dua baris menunjuk pendahulu
-- yang sama), tetap tanpa bergantung urutan `seq`. Kasus urutan-terbalik yang sah (O-038) tidak
-- terganggu: `prev_hash` baris-barisnya berbeda.
--
-- Yang **tetap** tidak terdeteksi: siklus tanpa genesis (membuatnya butuh titik tetap fungsi hash;
-- hash yang ditulis tangan sudah ketahuan lewat `row_hash_ok`) dan penulisan ulang seluruh ekor
-- rantai oleh penyerang ber-hak-tulis-penuh (batas lama, O-009, ditunda D-060).
--
-- Tanda tangan dan kolom hasil sengaja tidak berubah: pemanggil (`verifyChain`, `ctl verify-audit`)
-- tidak perlu disentuh. Expand-only: hanya CREATE (`CREATE OR REPLACE FUNCTION` seperti 0007 → 0009).

CREATE INDEX audit_log_hash_idx ON platform.audit_log (hash);
CREATE INDEX audit_log_prev_hash_idx ON platform.audit_log (prev_hash);

CREATE OR REPLACE FUNCTION platform.audit_verify(p_from_seq bigint DEFAULT 0)
RETURNS TABLE (seq bigint, row_hash_ok boolean, link_ok boolean,
               expected_hash text, actual_hash text)
LANGUAGE sql STABLE AS $fn$
  SELECT a.seq,
         a.hash = encode(
            digest(a.prev_hash || '|' || platform.audit_log_payload(a), 'sha256'),
            'hex') AS row_hash_ok,
         (a.prev_hash = repeat('0', 64) OR EXISTS (
            SELECT 1 FROM platform.audit_log b WHERE b.hash = a.prev_hash))
           AND NOT EXISTS (
            SELECT 1 FROM platform.audit_log c
            WHERE c.prev_hash = a.prev_hash AND c.seq <> a.seq) AS link_ok,
         encode(
            digest(a.prev_hash || '|' || platform.audit_log_payload(a), 'sha256'),
            'hex') AS expected_hash,
         a.hash AS actual_hash
  FROM platform.audit_log a
  WHERE a.seq >= p_from_seq
  ORDER BY a.seq
$fn$;
