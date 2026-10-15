#!/usr/bin/env bash
# audit-consistency.sh — bandingkan md5 skrip ops/scripts (repo) dengan versi
# yang terpasang di server (spec §21.6: deploy-vps.sh "md5 repo == server").
#
# Pelapor (exit 0 selalu) — hitung sendiri baris DRIFT/FAIL.
#
# Usage: [KRAN_VPS=user@host] ops/scripts/audit-consistency.sh [repo-dir]
#   - KRAN_VPS  tujuan SSH (WAJIB diisi; sengaja tidak di-hardcode agar alamat
#     server tidak tertanam di repo). Kosong => bagian remote dilewati.
#   - SSH_KEY  private key (default ~/.ssh/id_ed25519)
#   - KRAN_REMOTE_DIR  direktori skrip di server (default /srv/qouver/apps/kran/scripts)
#
# BELUM PERNAH DIJALANKAN DI SERVER (T-013).
set -uo pipefail

SELF_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_DIR="${1:-$(cd "$SELF_DIR/../.." && pwd)}"
SCRIPTS_DIR="$REPO_DIR/ops/scripts"
REMOTE="${KRAN_VPS:-}"
SSH_KEY="${SSH_KEY:-$HOME/.ssh/id_ed25519}"
REMOTE_DIR="${KRAN_REMOTE_DIR:-/srv/qouver/apps/kran/scripts}"

md5_of() {
  if command -v md5 >/dev/null 2>&1; then md5 -q "$1"
  else md5sum "$1" | cut -d' ' -f1; fi
}

fails=0
printf '=== skrip lokal (%s) ===\n' "$SCRIPTS_DIR"
for f in "$SCRIPTS_DIR"/*.sh; do
  [ -e "$f" ] || continue
  printf '  %s  %s\n' "$(md5_of "$f")" "$(basename "$f")"
done

if [ -z "$REMOTE" ]; then
  printf '\n[info] KRAN_VPS kosong — perbandingan server dilewati.\n'
  exit 0
fi

printf '\n=== repo vs server (%s:%s) ===\n' "$REMOTE" "$REMOTE_DIR"
if ! ssh -o ConnectTimeout=8 -o BatchMode=yes -i "$SSH_KEY" "$REMOTE" 'true' 2>/dev/null; then
  printf 'WARN: SSH ke %s gagal — lewati perbandingan\n' "$REMOTE"
  exit 0
fi

remote_listing="$(ssh -o ConnectTimeout=8 -i "$SSH_KEY" "$REMOTE" \
  "cd '$REMOTE_DIR' 2>/dev/null && for f in *.sh; do [ -f \"\$f\" ] && { if command -v md5 >/dev/null 2>&1; then s=\$(md5 -q \"\$f\"); else s=\$(md5sum \"\$f\" | cut -d' ' -f1); fi; printf '%s %s\n' \"\$f\" \"\$s\"; }; done" 2>/dev/null)"

for f in "$SCRIPTS_DIR"/*.sh; do
  [ -e "$f" ] || continue
  name="$(basename "$f")"
  local_md5="$(md5_of "$f")"
  remote_md5="$(printf '%s\n' "$remote_listing" | awk -v n="$name" '$1==n{print $2}')"
  if [ -z "$remote_md5" ]; then
    printf '  WARN %s: tidak ada di server\n' "$name"
  elif [ "$local_md5" = "$remote_md5" ]; then
    printf '  OK   %s: repo == server (%s)\n' "$name" "$local_md5"
  else
    printf '  DRIFT %s: repo=%s server=%s\n' "$name" "$local_md5" "$remote_md5"
    fails=$((fails + 1))
  fi
done

if [ "$fails" -eq 0 ]; then
  printf '\nSemua skrip sinkron.\n'
else
  printf '\n%d skrip DRIFT.\n' "$fails"
fi
exit 0
