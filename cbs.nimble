# Satu paket Nim untuk seluruh monorepo (lihat docs/DECISIONS.md D-002).
# Direktori sumber ditambahkan lewat `-p:` di ./task, bukan lewat `srcDir` tunggal.
version     = "0.1.0"
author      = "Fredianto"
description = "CBS Indonesia - core banking system (Nim backend + SvelteKit web)"
license     = "MIT"

requires "nim >= 2.2.0"
requires "db_connector >= 0.1.0"
requires "yaml >= 2.2.1"
# PBKDF2-HMAC-SHA256 untuk password (ADR/D-013). Sudah terpasang lokal sebagai 0.7.3.
requires "nimcrypto >= 0.7.3"
# HTTP server + WebSocket (ADR-002/D-019). Terpasang lokal sebagai 0.4.8.
# Mummy 0.4.8 yang diuji. `events.nim` memakai dua sifat yang **tidak** dijanjikan API publiknya:
# `WebSocket.send`/`close` aman dipanggil dari thread lain (antrean kirim per koneksi), dan
# `disconnect` idempoten. Karena itu kenaikan versi minor harus melewati daftar periksa di
# docs/DECISIONS.md (D-037) + uji O-049 di `apps/api/tests/itapi_ws.nim`.
requires "mummy >= 0.4.8 & < 0.5.0"
