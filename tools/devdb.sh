#!/usr/bin/env sh
#
# DB dev CBS - database `cbs_dev` di Postgres server (bukan di laptop; keputusan pemilik,
# dicatat di docs/DECISIONS.md D-004). Skrip ini hanya mengelola TUNNEL SSH, bukan DB-nya.
#
#   ./task devdb up      buka tunnel 127.0.0.1:55432 -> server 127.0.0.1:5432
#   ./task devdb down    tutup tunnel
#   ./task devdb status  cek tunnel + koneksi + versi migrasi
#   ./task devdb psql    masuk psql
#
# URL koneksi ada di .local/dev.env (gitignored, berisi password). Skrip TIDAK menyimpan
# kredensial dan TIDAK menjalankan apa pun di server.
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$ROOT"

ENVFILE="$ROOT/.local/dev.env"
SOCK="$ROOT/.local/devdb.sock"
LOCAL_PORT="${CBS_DEVDB_PORT:-55432}"
SSH_HOST="${CBS_DEVDB_SSH:-sachiel@43.133.148.191}"
SSH_KEY="${CBS_DEVDB_SSH_KEY:-$HOME/.ssh/id_ed25519}"
# Berapa lama master koneksi bertahan setelah idle (detik). Naikkan bila menjalankan
# test integrasi panjang; mesin-lokal, jangan dijadikan nilai di repo.
SSH_PERSIST="${CBS_DEVDB_PERSIST:-600}"

die() { printf '!! %s\n' "$*" >&2; exit 1; }
load_env() {
  [ -f "$ENVFILE" ] || die "belum ada $ENVFILE (lihat docs/runbooks/dev-db.md)"
  set -a
  . "$ENVFILE"
  set +a
}

probe() {
  # Bukti nyata bahwa tunnel hidup: query ke DB. `nc`/`ssh -O check` **tidak cukup** — port lokal
  # masih menerima koneksi walau SSH-nya sudah mati (tunnel basi), dan gejalanya baru muncul sebagai
  # "server closed the connection unexpectedly" di tengah test (kejadian 14–15 Okt 2026, 3×).
  [ -n "${CBS_DATABASE_URL:-}" ] || return 1
  command -v psql >/dev/null 2>&1 || return 1
  psql "$CBS_DATABASE_URL" -Atc 'select 1' >/dev/null 2>&1
}

up() {
  load_env
  if probe; then
    printf '   tunnel sudah jalan (query ke DB berhasil)\n'
    return 0
  fi
  # Tidak ada tunnel atau tunnel basi: buang sisa master connection lalu buka ulang.
  ssh -o ControlPath="$SOCK" -O exit "$SSH_HOST" 2>/dev/null || true
  mkdir -p "$ROOT/.local"
  # Keepalive: koneksi yang menganggur diputus jaringan/NAT tanpa opsi ini.
  ssh -f -N \
    -o BatchMode=yes -o ExitOnForwardFailure=yes \
    -o ServerAliveInterval=30 -o ServerAliveCountMax=3 -o TCPKeepAlive=yes \
    -o ControlMaster=yes -o ControlPath="$SOCK" -o ControlPersist="$SSH_PERSIST" \
    -i "$SSH_KEY" \
    -L "127.0.0.1:$LOCAL_PORT:127.0.0.1:5432" \
    "$SSH_HOST"
  probe || die "tunnel terbuka tetapi query ke DB gagal (cek $ENVFILE / DB server)"
  printf '   tunnel dibuka: 127.0.0.1:%s -> %s:5432\n' "$LOCAL_PORT" "$SSH_HOST"
}

down() {
  if ssh -o ControlPath="$SOCK" -O exit "$SSH_HOST" 2>/dev/null; then
    printf '   tunnel ditutup\n'
  else
    printf '   tidak ada tunnel aktif\n'
  fi
}

status() {
  load_env
  command -v psql >/dev/null 2>&1 || die "psql tidak ada di PATH"
  psql "$CBS_DATABASE_URL" -Atc "select current_database() || ' @ ' || version()"
}

case "${1:-status}" in
  up) up ;;
  down) down ;;
  status) status ;;
  psql) load_env; exec psql "$CBS_DATABASE_URL" "$@" ;;
  url) load_env; printf '%s\n' "$CBS_DATABASE_URL" ;;
  *) die "perintah tidak dikenal: $1 (up|down|status|psql|url)" ;;
esac
