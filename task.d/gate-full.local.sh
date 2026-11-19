#!/usr/bin/env sh
# cbs test hook for `./task gate-full`.
# Runs the suite CI runs at the end of a release: check, build, test and e2e. It needs a local
# Postgres (KRAN_DATABASE_URL via .local/dev.env); without one the gate fails and says why.
set -eu
cd "$(dirname "$0")/.."

sh ./task check
sh ./task build
sh ./task test
sh ./task e2e
