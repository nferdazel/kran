# Satu paket Nim untuk seluruh monorepo (lihat docs/DECISIONS.md D-002).
# Nama berkas = nama paket Nim; ikut nama repo sejak D-038 (`kran`).
# Direktori sumber ditambahkan lewat `-p:` di ./task, bukan lewat `srcDir` tunggal.
version     = "0.1.0"
author      = "Fredianto"
description = "KRAN - core banking system (Nim backend + SvelteKit web)"
# `LICENSE` di akar repo adalah sumber kebenaran lisensi: publik untuk dibaca/audit, **tanpa** izin
# pakai ulang (D-044). Field ini wajib diisi Nimble (nimble menolak `.nimble` tanpa license) dan
# `"Proprietary"` bukan id SPDX — nilai apa pun di sini **bukan** pemberian lisensi.
license     = "Proprietary"

# Versi dependensi **dipin persis** (O-059): build yang di-deploy harus memakai versi yang sama dengan
# yang diuji, bukan "versi terbaru yang cocok". Catatan: ini bukan pengganti penuh berkas lock —
# revisi git dependensi tidak ikut terpin, hanya nomor versinya.
#
# Toolchain ikut dipin: angka 2.4.0 di bawah dipakai juga oleh `.github/workflows/ci.yml`
# (setup-nim) dan `apps/api/Dockerfile` (tarball resmi + sha256), supaya yang diuji = yang di-deploy.
requires "nim >= 2.4.0 & < 2.5.0"
requires "db_connector == 0.1.0"
requires "yaml == 2.2.1"
# PBKDF2-HMAC-SHA256 untuk password (ADR/D-013).
requires "nimcrypto == 0.7.3"
# HTTP server + WebSocket (ADR-002/D-019).
# `events.nim` memakai dua sifat yang **tidak** dijanjikan API publiknya: `WebSocket.send`/`close`
# aman dipanggil dari thread lain (antrean kirim per koneksi), dan `disconnect` idempoten. Karena itu
# menaikkan versi ini **wajib** melewati daftar periksa di docs/DECISIONS.md (D-037) + uji O-049 di
# `apps/api/tests/itapi_ws.nim`.
requires "mummy == 0.4.8"
