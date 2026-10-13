#!/usr/bin/env bash
# deploy-vps.sh — kontrak deploy CBS di VPS (spec §21.4, §21.5, §21.7).
#
# Dipanggil webhook adnanh/webhook (hook `cbs`) dengan argumen:
#   $1 = repository.name (mis. "cbs")
#   $2 = ref             (mis. "refs/heads/main")
#
# Langkah (spec §21.4): ref-guard -> lock -> fetch/reset -> FREEZE GATE ->
# rebuild selektif -> pre-migration dump -> build + ekstrak binary ->
# MIGRATION GATE (expand-only) -> swap web -> restart -> HEALTH GATE +
# auto-rollback -> .deployed_rev -> self-update.
#
# Tanpa secret di repo: URL repo + kredensial hanya dari env VPS (mode 600),
# mis. CBS_GIT_URL=github-cbs:<user>/cbs.git
#
# BELUM PERNAH DIJALANKAN DI SERVER (T-013). Semua path mengikuti §21.5;
# verifikasi di server sebelum diandalkan.
set -euo pipefail

REPO="${1:-cbs}"
REF="${2:-}"

APP_DIR="${CBS_APP_DIR:-/srv/qouver/apps/cbs}"
MONO_DIR="$APP_DIR/monorepo"
BIN="$APP_DIR/bin/cbs-api"
BIN_NEW="$APP_DIR/bin/cbs-api.new"
BIN_PREV="$APP_DIR/bin/cbs-api.prev"
STATE_FILE="$APP_DIR/.deployed_rev"
LOG="$APP_DIR/logs/deploy.log"
HEALTH_URL="${CBS_HEALTH_URL:-http://127.0.0.1:8095/readyz}"

mkdir -p "$APP_DIR/logs"
log() { printf '[%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*" | tee -a "$LOG"; }
die() { log "ERROR: $*"; exit 1; }

log "Deploy trigger received for: $REPO ref=${REF:-<none>}"

# 1. Ref-guard fail-closed (spec §21.4 #1): hanya push ke main.
if [ -n "$REF" ] && [ "$REF" != "refs/heads/main" ]; then
  log "==> skip: ref=$REF (bukan refs/heads/main)"
  exit 0
fi

# 2. Lock (spec §21.4 #2): satu deploy pada satu waktu.
exec 9>"$APP_DIR/.deploy.lock"
if ! flock -n 9; then
  log "==> deploy lain sedang berjalan; keluar tanpa menunggu"
  exit 0
fi

if [ -z "${CBS_GIT_URL:-}" ]; then
  die "CBS_GIT_URL tidak diset (mis. github-cbs:<user>/cbs.git)"
fi

# 3. Fetch + reset (spec §21.4 #3).
IS_FIRST=0
if [ -d "$MONO_DIR/.git" ]; then
  cd "$MONO_DIR" || die "gagal masuk $MONO_DIR"
  if [ -f "$STATE_FILE" ]; then OLD_REV="$(cat "$STATE_FILE")"; else OLD_REV=""; fi
  git fetch origin main && git reset --hard origin/main
  NEW_REV="$(git rev-parse HEAD 2>/dev/null || echo '')"
  if [ -n "$OLD_REV" ] && [ "$OLD_REV" != "$NEW_REV" ]; then
    # *.md tidak memicu rebuild (gaya skyward): dokumen bukan input build.
    CHANGED_FILES="$(git diff --name-only "$OLD_REV" "$NEW_REV" -- ':(exclude)*.md' 2>/dev/null \
      || echo 'apps/ modules/ shared/ migrations/')"
  else
    CHANGED_FILES="apps/ modules/ shared/ migrations/"
  fi
else
  log "Cloning cbs -> $MONO_DIR"
  git clone "$CBS_GIT_URL" "$MONO_DIR"
  NEW_REV="$(git -C "$MONO_DIR" rev-parse HEAD 2>/dev/null || echo '')"
  CHANGED_FILES="apps/ modules/ shared/ migrations/"
  IS_FIRST=1
fi

REVID="${NEW_REV:0:12}"
[ -n "$REVID" ] || REVID="unknown"

# Self-update: sinkronkan skrip repo -> server. Pakai .new + mv (rename) supaya
# bash tidak membaca file yang sedang ditimpa — lihat catatan di skyward.
sync_script() {
  local src="$1" dst="$2"
  if [ -f "$src" ] && ! cmp -s "$src" "$dst"; then
    if cp -f "$src" "$dst.new" && chmod +x "$dst.new" && mv -f "$dst.new" "$dst"; then
      log "==> $(basename "$dst") diperbarui dari repo (berlaku deploy berikutnya)"
    else
      log "==> WARN: gagal memperbarui $dst"
    fi
  fi
}
mkdir -p "$APP_DIR/scripts"
for src in "$MONO_DIR"/ops/scripts/*.sh; do
  [ -e "$src" ] || continue
  sync_script "$src" "$APP_DIR/scripts/$(basename "$src")"
done

# 4. FREEZE GATE (spec §21.4 #4, §11.7): jangan deploy saat day-close berjalan.
if [ -x "$BIN" ]; then
  freeze_out="$("$BIN" --role=ctl daycloser-status 2>&1 || true)"
  if grep -qE '(^|[^A-Z])(RUNNING|CLOSING)([^A-Z]|$)' <<<"$freeze_out"; then
    log "==> FREEZE: day-close RUNNING/CLOSING; deploy dibatalkan (coba lagi setelah selesai)"
    log "    status: $freeze_out"
    exit 0
  fi
else
  log "==> WARN: $BIN belum ada; FREEZE GATE dilewati pada deploy pertama"
fi

# 5 (rebuild selektif) diterapkan lewat kondisi grep per komponen di bawah.
# 6. Pre-migration dump bila ada perubahan migrasi (spec §21.4 #6).
MIGRATIONS_CHANGED=0
if [ "$IS_FIRST" -eq 1 ] || grep -qE 'migrations/' <<<"$CHANGED_FILES"; then
  MIGRATIONS_CHANGED=1
  if [ -x "$APP_DIR/scripts/backup-pre-deploy.sh" ]; then
    "$APP_DIR/scripts/backup-pre-deploy.sh" "$REVID" || die "pre-migration dump gagal; deploy dibatalkan"
  else
    log "==> WARN: scripts/backup-pre-deploy.sh belum terpasang; pre-migration dump dilewati"
  fi
fi

# 7. Build + ekstrak binary (spec §21.4 #7). Rebuild hanya bila input build berubah.
if [ "$IS_FIRST" -eq 1 ] || grep -qE '^(apps/api/|modules/|shared/|cbs\.nimble|cbs\.lock)' <<<"$CHANGED_FILES"; then
  log "==> Build API (podman, tag :local + :$REVID)..."
  [ -d "$MONO_DIR/apps/api" ] || die "apps/api tidak ditemukan"
  cd "$MONO_DIR/apps/api" || die "gagal masuk apps/api"
  podman build -t localhost/cbs-api:local -t "localhost/cbs-api:$REVID" .
  mkdir -p "$APP_DIR/bin"
  build_cid="$(podman create "localhost/cbs-api:$REVID")"
  podman cp "$build_cid:/usr/local/bin/cbs-api" "$BIN_NEW"
  podman rm "$build_cid" >/dev/null
  chmod +x "$BIN_NEW"
else
  log "==> kode API tidak berubah; build dilewati"
fi

# 8. MIGRATION GATE (spec §21.4 #8, expand-only) memakai binary BARU, sebelum
#    binary ditukar: gagal => deploy dibatalkan dan binary lama tetap utuh.
if [ "$MIGRATIONS_CHANGED" -eq 1 ]; then
  MIGRATE_BIN="$BIN_NEW"
  [ -x "$MIGRATE_BIN" ] || MIGRATE_BIN="$BIN"
  [ -x "$MIGRATE_BIN" ] || die "tidak ada binary untuk migration gate"
  log "==> MIGRATION GATE: --check"
  "$MIGRATE_BIN" --role=migrate --check || die "migrasi --check gagal (expand-only)"
  log "==> MIGRATION GATE: --up"
  "$MIGRATE_BIN" --role=migrate --up || die "migrasi --up gagal"
else
  log "==> migrasi tidak berubah; gate dilewati"
fi

# Tukar binary (lama -> .prev) hanya setelah gate lolos.
if [ -f "$BIN_NEW" ]; then
  if [ -f "$BIN" ]; then cp -f "$BIN" "$BIN_PREV"; fi
  mv -f "$BIN_NEW" "$BIN"
  chmod +x "$BIN"
fi

# 9. Web: build statis lalu swap atomik (`web.new` -> `web`, `web.prev` disimpan).
if [ "$IS_FIRST" -eq 1 ] || grep -qE '^(apps/web/|packages/)' <<<"$CHANGED_FILES"; then
  if [ -f "$MONO_DIR/apps/web/package.json" ]; then
    log "==> Build web (pnpm)..."
    cd "$MONO_DIR/apps/web" || die "gagal masuk apps/web"
    export COREPACK_ENABLE_DOWNLOAD_PROMPT=0
    corepack pnpm install --frozen-lockfile
    corepack pnpm run build
    if [ -d "$MONO_DIR/apps/web/build" ]; then
      rm -rf "$APP_DIR/web.new"
      cp -a "$MONO_DIR/apps/web/build" "$APP_DIR/web.new"
      rm -rf "$APP_DIR/web.prev"
      if [ -d "$APP_DIR/web" ]; then mv "$APP_DIR/web" "$APP_DIR/web.prev"; fi
      mv "$APP_DIR/web.new" "$APP_DIR/web"
      # SELinux: berkas baru berlabel var_t -> Caddy tidak bisa membaca.
      restorecon -RF "$APP_DIR/web" 2>/dev/null || true
      log "==> web swapped"
    else
      die "build web tidak menghasilkan folder build/"
    fi
  else
    log "==> WARN: apps/web belum ada (T-010); web dilewati"
  fi
else
  log "==> web tidak berubah; dilewati"
fi

# 10. Restart unit (spec §21.4 #10).
log "==> restart cbs-api & cbs-worker"
systemctl --user daemon-reload
systemctl --user restart cbs-api
systemctl --user restart cbs-worker

# 11. HEALTH GATE + auto-rollback (spec §21.4 #11): poll /readyz x15.
healthy=0
for _ in {1..15}; do
  if curl -fsS --max-time 3 "$HEALTH_URL" >/dev/null 2>&1; then
    healthy=1
    break
  fi
  sleep 2
done

if [ "$healthy" -ne 1 ]; then
  log "==> ERROR: $HEALTH_URL tidak sehat setelah restart; auto-rollback"
  if [ -f "$BIN_PREV" ]; then
    cp -f "$BIN_PREV" "$BIN"
    chmod +x "$BIN"
  fi
  if [ -d "$APP_DIR/web.prev" ]; then
    rm -rf "$APP_DIR/web"
    mv "$APP_DIR/web.prev" "$APP_DIR/web"
  fi
  systemctl --user restart cbs-api || true
  systemctl --user restart cbs-worker || true
  exit 1
fi
log "==> API sehat ($HEALTH_URL OK)"

# 12. State + log (spec §21.4 #12). Journal menerima stdout via systemd webhook.
if [ -n "${NEW_REV:-}" ]; then printf '%s\n' "$NEW_REV" > "$STATE_FILE"; fi
log "Deployment completed successfully for $REPO ($REVID)"