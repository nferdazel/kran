# Provisioning pilot (produksi)

Runbook ini menyiapkan data pilot yang cukup untuk memakai alur teller end-to-end:
periode buku, produk simpanan, rekening, dan satu hari kas teller. Semua langkah bisnis
lewat API publik supaya maker-checker, audit, dan posting rule berjalan seperti operator.

Data pilot **sengaja dipertahankan** (disetujui pemilik 23 Okt 2026) dan memakai data
sintetis, bukan data anggota nyata.

## 1. Prasyarat

- Biner `kran-api` versi yang memuat `ctl create-user` sudah ter-deploy.
- Migrasi `platform/0027_platform_rbac_pilot_roles.sql` sudah diterapkan (role `teller`,
  izin produk untuk `product_checker`).
- Migrasi `platform/0028_platform_rbac_role_scope.sql` sudah diterapkan: menambahkan kolom
  `platform.role.scope` (`INSTITUTION`/`BRANCH`, `teller` = `BRANCH`), memberi `teller` izin
  `platform.param.read` (agar pintasan F4/F5/F9 dari `platform.ui.shortcut.*` bisa dimuat UI),
  dan menyediakan perintah siklus hidup akun di bawah.
- Akses DB produksi untuk satu penyesuaian data: memindahkan party demo ke cabang pilot.

## 2. Akun operator

Tiga peran dipakai:

| Akun | Role | Cabang | Dipakai untuk |
|---|---|---|---|
| `admin` | `platform_admin` | global | buka periode, buat produk (maker), buka rekening |
| `checker.pilot` | `product_checker` | global | menyetujui produk (checker ≠ maker) |
| `teller.pilot` | `teller` | `b0000000-0000-4000-8000-000000000001` | sesi kas, setor tunai, PB |

`kran-api` hanya punya `bootstrap-admin` untuk admin pertama. Akun berikutnya memakai:

```sh
podman exec kran-api /usr/local/bin/kran-api --role=ctl create-user \
  --username=checker.pilot --user-role=product_checker --full-name="Checker Pilot"

podman exec kran-api /usr/local/bin/kran-api --role=ctl create-user \
  --username=teller.pilot --user-role=teller \
  --branch=b0000000-0000-4000-8000-000000000001 --full-name="Teller Pilot"
```

Kata sandi awal dicetak **sekali** (`must_change_password = true`). Login lalu ganti lewat
`POST /api/v1/auth/password` sebelum dipakai; tanpa itu semua rute lain menjawab 403.

### Scope role (ditegakkan sejak 0028)

- Role `BRANCH` (hanya `teller`) **wajib** diberi `--branch=<uuid>`; tanpa itu perintahnya ditolak
  (kode 3) — bukan diberi grant global yang melihat semua cabang.
- Role `INSTITUTION` (`product_checker`, `platform_admin`, `param_*`) **wajib tanpa** `--branch`;
  memberinya cabang ditolak (kode 3) — sebelumnya menghasilkan akun mati karena rute institusi
  mengotorisasi pada cabang kosong.

### Siklus hidup akun

Perintah berikut memakai disiplin yang sama dengan `create-user`/`reset-password` (satu transaksi,
audit, pencabutan sesi bila relevan). Kode keluar: 2 salah pakai, 3 ditolak/tidak ditemukan.

```sh
# Menugaskan/mencabut role (role BRANCH butuh --branch; role INSTITUTION tanpa --branch)
podman exec kran-api /usr/local/bin/kran-api --role=ctl assign-role \
  --username=teller.pilot --user-role=teller --branch=b0000000-0000-4000-8000-000000000001
podman exec kran-api /usr/local/bin/kran-api --role=ctl revoke-role \
  --username=teller.pilot --user-role=teller --branch=b0000000-0000-4000-8000-000000000001

# Offboarding: nonaktifkan + cabut semua sesi. Mengaktifkan kembali hanya untuk akun INACTIVE.
podman exec kran-api /usr/local/bin/kran-api --role=ctl disable-user --username=teller.pilot
podman exec kran-api /usr/local/bin/kran-api --role=ctl enable-user --username=teller.pilot

# Membuka akun yang terkunci lockout (hanya LOCKED -> ACTIVE; mengosongkan penghitung gagal).
podman exec kran-api /usr/local/bin/kran-api --role=ctl unlock-user --username=teller.pilot
```

`revoke-role` menolak mencabut `platform_admin` terakhir (kode 3) supaya tidak ada keadaan tanpa
admin. `enable-user` tidak menyentuh akun `LOCKED`/`SUSPENDED` — pakai `unlock-user` untuk lockout.

## 3. Cabang pilot

D-129 menetapkan `b0000000-0000-4000-8000-000000000001` sebagai cabang pilot dan vault kas
berada di cabang itu. Party demo bawaan masih berada di UUID demo lain, jadi disamakan dulu
(satu kali, sebelum ada rekening):

```sql
UPDATE party.party
   SET branch_id = 'b0000000-0000-4000-8000-000000000001', updated_at = now()
 WHERE branch_id = '00000000-0000-4000-8000-000000000001';
```

Tanpa ini pembukaan rekening ditolak `branch_mismatch`, dan sesi kas di cabang party akan
`vault_not_configured`.

## 4. Periode dan produk

1. `POST /api/v1/ledger/periods` `{"startsOn":"2026-10-01","endsOn":"2026-10-31"}`.
   Transaksi tunai ditolak `period_closed` bila tidak ada periode OPEN.
2. `POST /api/v1/products` sebagai `admin` untuk setiap produk, lalu
   `POST /api/v1/products/{code}/versions/{versionId}/approve` sebagai `checker.pilot`.

Produk pilot:

| Kode | Nama | savingsKind | min_balance |
|---|---|---|---|
| `SIMP-POKOK` | Simpanan Pokok | `POKOK` | 0 |
| `SIMP-WAJIB` | Simpanan Wajib | `WAJIB` | 0 |
| `SIMP-SUKARELA` | Simpanan Sukarela | `SUKARELA` | 10.000 |
| `TABUNGAN` | Tabungan Anggota | `TABUNGAN` | 25.000 |

Semua produk memakai `interest_posting = NONE` dan `interest_rate = 0` karena mesin bunga
belum ada di Fase 2 — jangan menampilkan angka bunga yang tidak dihitung.

## 5. Rekening dan hari kas

1. Buka rekening (`POST /api/v1/deposit/accounts`, wajib `Idempotency-Key`) untuk:
   Agus (pokok + wajib), Budi (tabungan), Dewi (tabungan), Siti (sukarela).
2. Buka sesi kas teller (`POST /api/v1/teller/sessions`) dengan float Rp2.000.000.
3. Setor tunai (`POST /api/v1/teller/cash-transactions`) dan satu PB
   (`POST /api/v1/teller/transfers`).
4. Tutup sesi (`POST /api/v1/teller/sessions/{id}/close`) dengan `countedCash` = float +
   seluruh setoran tunai.

Semua POST wajib `Idempotency-Key`; kunci tetap (deterministik) membuat pengulangan aman
untuk rekening/transaksi. Pembukaan produk **tidak** idempoten per kode — cek katalog dulu
sebelum mengulang.

## 6. Verifikasi

- `GET /api/v1/deposit/accounts?partyId=…` menampilkan saldo hasil transaksi.
- `GET /api/v1/deposit/accounts/{id}/statement?from=…&to=…` menampilkan mutasi.
- `GET /api/v1/teller/vault?branchId=…` = vault awal − float + kas hasil hitung.
- `GET /api/v1/ledger/journals` dan trial balance menunjukkan jurnal double-entry.
- Audit: `user.create`, `product.*`, `deposit.account.open`, `teller.*` ada di
  `GET /api/v1/audit` (atau `platform.audit_log`).

## 7. Batas yang masih berlaku

- Kas teller/variance belum masuk GL (O-097); top-up vault belum maker-checker (O-098/O-099).
- `branch_id` masih UUID placeholder tanpa master cabang (O-101).
- Kata sandi pilot harus diganti setelah serah terima; jangan disimpan di repo.
