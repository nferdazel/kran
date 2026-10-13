# Satu paket Nim untuk seluruh monorepo (lihat docs/DECISIONS.md D-002).
# Direktori sumber ditambahkan lewat `-p:` di ./task, bukan lewat `srcDir` tunggal.
version     = "0.1.0"
author      = "Fredianto"
description = "CBS Indonesia - core banking system (Nim backend + SvelteKit web)"
license     = "MIT"

requires "nim >= 2.2.0"
requires "db_connector >= 0.1.0"
requires "yaml >= 2.2.1"
