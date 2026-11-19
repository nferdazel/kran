#!/usr/bin/env sh
# cbs fast static checks for `./task gate`: no database, no browser, installs nothing.
# The full suite (check + build + test + e2e) lives in gate-full.local.sh.
set -eu
cd "$(dirname "$0")/.."

if ! command -v nim >/dev/null 2>&1; then
  printf '   nim not on PATH: static checks skipped here (CI runs them)\n'
  exit 0
fi

sh ./task check-fast
