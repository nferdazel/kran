-- Indeks untuk rebuild cache per tanggal (T-075 review): DELETE ... WHERE as_of = ? tidak bisa
-- memakai PK (account_code, as_of) karena prefix-nya account_code.
CREATE INDEX balance_snapshot_as_of_idx ON ledger.balance_snapshot (as_of);
