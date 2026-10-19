#!/usr/bin/env bash
# deploy-vps.sh — kontrak deploy KRAN di VPS (spec §21.4, §21.5, §21.7).
#
# Dipanggil webhook adnanh/webhook (hook `kran`) dengan argumen:
#   $1 = repository.name (mis. "kran")
#   $2 = ref             (mis. "refs/heads/main")
#
# Langkah (spec §21.4): ref-guard -> lock -> fetch/reset -> FREEZE GATE ->
# rebuild selektif -> pre-migration dump -> build + ekstrak binary (untuk gate) ->
# MIGRATION GATE (expand-only) -> swap web -> restart container -> HEALTH GATE +
# auto-rollback -> .deployed_rev -> self-update (skrip + unit quadlet).
#
# Tanpa secret di repo: URL repo + kredensial hanya dari env VPS (mode 600),
# mis. KRAN_GIT_URL=github-kran:<user>/kran.git
#
# BELUM PERNAH DIJALANKAN DI SERVER (T-013). Semua path mengikuti §21.5;
# verifikasi di server sebelum diandalkan.
set -euo pipefail

REPO="${1:-kran}"
REF="${2:-}"

APP_DIR="${KRAN_APP_DIR:-/srv/qouver/apps/kran}"
MONO_DIR="$APP_DIR/monorepo"
# Biner native: DIPAKAI HANYA OLEH GATE DI SKRIP INI (FREEZE GATE & MIGRATION GATE), yang memang
# berjalan di host sebelum layanan di-restart. Layanan `--role=api` sendiri jalan dari image lewat
# quadlet `ops/systemd/kran-api.container`.
BIN="$APP_DIR/bin/kran-api"
BIN_NEW="$APP_DIR/bin/kran-api.new"
BIN_PREV="$APP_DIR/bin/kran-api.prev"
STATE_FILE="$APP_DIR/.deployed_rev"
LOG="$APP_DIR/logs/deploy.log"

# Runtime lib untuk biner GATE. Host (Rocky 9) tidak punya libpq, sedangkan biner dibangun di image
# Debian; karena itu lib di-vendor ke $APP_DIR/lib dan dipakai lewat LD_LIBRARY_PATH. Container
# `kran-api` tidak memakai jalur ini — image-nya sudah memuat libpq5 + libpcre3. Kalau kelak
# `libpq` dipasang di host, blok vendor di bawah boleh dihapus.
LIB_DIR="$APP_DIR/lib"
export LD_LIBRARY_PATH="$LIB_DIR${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
HEALTH_URL="${KRAN_HEALTH_URL:-http://127.0.0.1:8095/readyz}"
# Unit quadlet user (podman); dipasang dari repo oleh `sync_units` di bawah.
UNIT_DIR="${KRAN_UNIT_DIR:-$HOME/.config/containers/systemd}"

mkdir -p "$APP_DIR/logs"
log() { printf '[%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*" | tee -a "$LOG"; }
die() { log "ERROR: $*"; exit 1; }

# Konfigurasi aplikasi (termasuk KRAN_DATABASE_URL/KEK). Unit systemd memuatnya lewat
# EnvironmentFile, tetapi jalur hook (webhook.service) tidak mewarisi env itu — deploy dari push
# gagal di migration gate dengan "KRAN_DATABASE_URL kosong" (ditemukan di T-045, 16 Okt 2026).
# Karena itu skrip ini yang memuatnya; nilai yang tidak ada di berkas (mis. KRAN_HEALTH_URL dari
# drop-in webhook) tetap dari lingkungan.
ENV_FILE="${KRAN_ENV_FILE:-$APP_DIR/env/kran-prod.env}"
if [ -f "$ENV_FILE" ]; then
  set -a
  # shellcheck disable=SC1090
  . "$ENV_FILE"
  set +a
  log "==> env aplikasi dimuat: $ENV_FILE"
fi

# Container dijalankan quadlet `kran-api.container`, dan di sana `--port`/`--address`/`--root`
# ditulis eksplisit (quadlet tidak melakukan interpolasi env yang bisa diandalkan). Karena itu
# KRAN_PORT/KRAN_BIND_HOST tidak lagi diteruskan unit — dulu baris ini memvalidasinya supaya
# systemd tidak mengirim argumen kosong.
#
# Yang sekarang perlu dijembatani: env prod memakai nama service network podman
# (`@qouver-postgres:5432`) karena itu yang bisa di-resolve container, sedangkan FREEZE GATE dan
# MIGRATION GATE menjalankan biner di HOST — dari host, nama itu tidak ada, dan postgres
# dipublikasikan di 127.0.0.1:5432. Satu berkas env, dua dunia.
GATE_DB_URL="${KRAN_DATABASE_URL//@qouver-postgres:/@127.0.0.1:}"
if [ "${KRAN_DATABASE_URL:-}" = "$GATE_DB_URL" ]; then
  log "==> WARN: KRAN_DATABASE_URL tidak memakai @qouver-postgres: — gate host memakai nilai apa adanya"
fi

# Salin lib runtime yang tidak ada di host dari image yang baru dibangun. Nama tujuan = **soname**
# (bukan nama berkas asli) karena `podman cp` mengikuti symlink: tanpa ini `libpq.so.5` hilang dan
# biner gagal start dengan `could not load: libpq.so(.5|)`. Rantainya terbukti di Rocky 9
# (16 Okt 2026): libpq.so.5 -> libldap-2.5.so.0 -> liblber-2.5.so.0 -> libsasl2.so.2.
# Rantai yang kurang akan terlihat di MIGRATION GATE di bawah, bukan diam-diam.
vendor_runtime_libs() {
  mkdir -p "$LIB_DIR"
  local cid; cid="$(podman create "$1")"
  local item src soname
  for item in \
    "usr/lib/x86_64-linux-gnu/libpq.so.5.15:libpq.so.5" \
    "usr/lib/x86_64-linux-gnu/libldap-2.5.so.0.1.8:libldap-2.5.so.0" \
    "usr/lib/x86_64-linux-gnu/liblber-2.5.so.0.1.8:liblber-2.5.so.0" \
    "usr/lib/x86_64-linux-gnu/libsasl2.so.2.0.25:libsasl2.so.2"; do
    src="${item%%:*}"; soname="${item##*:}"
    if [ -n "$src" ] && podman cp "$cid:/$src" "$LIB_DIR/$soname" >/dev/null 2>&1; then
      log "   lib runtime: $soname"
    fi
  done
  podman rm "$cid" >/dev/null 2>&1 || true
}

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

if [ -z "${KRAN_GIT_URL:-}" ]; then
  die "KRAN_GIT_URL tidak diset (mis. github-kran:<user>/kran.git)"
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
      || printf '%s\n' apps/api/ apps/web/ modules/ shared/ tools/ migrations/ kran.nimble)"
  else
    # Satu path per baris: grep per komponen di bawah ber-anchor `^`. (Sebelum ini daftarnya satu
    # baris dipisah spasi, sehingga `^apps/api/` tidak pernah cocok dan build API dilewati di
    # deploy pertama — ditemukan di latihan T-045, 16 Okt 2026.)
    CHANGED_FILES="$(printf '%s\n' apps/api/ apps/web/ modules/ shared/ tools/ migrations/ kran.nimble)"
  fi
else
  log "Cloning kran -> $MONO_DIR"
  git clone "$KRAN_GIT_URL" "$MONO_DIR"
  NEW_REV="$(git -C "$MONO_DIR" rev-parse HEAD 2>/dev/null || echo '')"
  # Satu path per baris: grep per komponen di bawah ber-anchor `^`. (Sebelum ini daftarnya satu
  # baris dipisah spasi, sehingga `^apps/api/` tidak pernah cocok dan build API dilewati di deploy
  # pertama — ditemukan di latihan T-045, 16 Okt 2026.)
  CHANGED_FILES="$(printf '%s\n' apps/api/ apps/web/ modules/ shared/ tools/ migrations/ kran.nimble)"
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

# Unit quadlet: sebelumnya deploy hanya `daemon-reload` + restart, jadi perubahan
# `ops/systemd/*.service` di repo **tidak pernah** sampai ke server. Sekarang unit yang dipasang
# adalah `*.container` (quadlet di ~/.config/containers/systemd, bukan ~/.config/systemd/user), dan
# salinan lama disimpan sebagai `.prev` supaya rollback bisa mengembalikannya.
#
# Validasi: `systemd-analyze verify` tidak bisa membaca berkas quadlet (itu bukan unit systemd).
# Yang dipakai: kehadiran seksi `[Container]` sebagai penjaga murah terhadap berkas terpotong —
# selebihnya divalidasi podman-user-generator saat `daemon-reload`, dan kegagalannya muncul di
# HEALTH GATE (bukan diam-diam).
#
# Unit `*.service` lama sengaja dipindah ke `ops/systemd/superseded/`, bukan sekadar ditandai di
# tempatnya: deploy yang masih memakai versi skrip lama (yang glob-nya `ops/systemd/*.service`)
# akan memasangnya kembali ke ~/.config/systemd/user, unit native menutupi quadlet bernama sama,
# dan API mati — persis yang terjadi 2026-10-19 saat deploy pertama setelah cutover. Di dalam
# subdirektori, tak ada glob yang bisa mengambilnya.
sync_units() {
  mkdir -p "$UNIT_DIR"
  local src name dst
  for src in "$MONO_DIR"/ops/systemd/*.container; do
    [ -e "$src" ] || continue
    name="$(basename "$src")"
    dst="$UNIT_DIR/$name"
    if [ -f "$dst" ] && cmp -s "$src" "$dst"; then continue; fi
    if ! grep -q '^\[Container\]' "$src"; then
      die "unit $name tidak punya seksi [Container]; deploy dibatalkan"
    fi
    if [ -f "$dst" ]; then cp -f "$dst" "$dst.prev" || log "==> WARN: gagal mencadangkan $dst"; fi
    if cp -f "$src" "$dst.new" && mv -f "$dst.new" "$dst"; then
      log "==> unit $name dipasang dari repo (cadangan: $name.prev)"
    else
      log "==> WARN: gagal memasang unit $name"
    fi
  done
}

# Dipanggil di jalur auto-rollback: kembalikan unit yang diganti deploy ini.
restore_units() {
  local prev target
  for prev in "$UNIT_DIR"/*.container.prev; do
    [ -e "$prev" ] || continue
    target="${prev%.prev}"
    if cp -f "$prev" "$target"; then log "==> rollback unit: $(basename "$target")"; fi
  done
}

sync_units

# ── Gate unit: layanan kini container (quadlet), bukan unit native ──
# Unit native ~/.config/systemd/user/kran-api.service dan unit hasil generator quadlet bernama
# sama, dan yang native MENANG. Kalau file itu masih ada, `systemctl --user restart kran-api`
# me-restart biner lama sementara health gate tetap hijau (dibaca dari biner itu juga) — deploy
# melaporkan sukses tanpa ada yang berubah. Fail-closed.
for native in kran-api.service kran-worker.service; do
  if [ -e "$HOME/.config/systemd/user/$native" ]; then
    log "==> ERROR: ~/.config/systemd/user/$native masih ada — unit native menutupi quadlet."
    log "    Pindahkan dulu (mis. mv ke $native.disabled), lalu: systemctl --user daemon-reload"
    exit 1
  fi
done

# 4. FREEZE GATE (spec §21.4 #4, §11.7): jangan deploy saat day-close berjalan.
# Biner gate jalan di host => pakai URL host (GATE_DB_URL), bukan nama service podman.
if [ -x "$BIN" ]; then
  freeze_out="$(KRAN_DATABASE_URL="$GATE_DB_URL" "$BIN" --role=ctl daycloser-status 2>&1 || true)"
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
if [ "$IS_FIRST" -eq 1 ] || grep -qE '^(apps/api/|modules/|shared/|tools/|kran\.nimble|nimble\.lock)' <<<"$CHANGED_FILES"; then
  log "==> Build API (podman, tag :local + :$REVID)..."
  [ -d "$MONO_DIR/apps/api" ] || die "apps/api tidak ditemukan"
  # Konteks build = root monorepo, bukan apps/api: sumber Nim ada di shared/ + modules/ + tools/
  # (beda dari pola Skyward yang modulnya mandiri). Dockerfile-nya di apps/api/Dockerfile.
  cd "$MONO_DIR" || die "gagal masuk $MONO_DIR"
  # Simpan image sebelumnya: rollback LAYANAN memakai tag image. Biner di bawah bukan untuk
  # layanan, hanya supaya gate (FREEZE/MIGRATION) bisa menjalankan versi yang baru dibangun.
  if podman image exists localhost/kran-api:local; then
    podman tag localhost/kran-api:local localhost/kran-api:prev 2>/dev/null || true
  fi
  podman build -f apps/api/Dockerfile -t localhost/kran-api:local -t "localhost/kran-api:$REVID" .
  mkdir -p "$APP_DIR/bin"
  build_cid="$(podman create "localhost/kran-api:$REVID")"
  podman cp "$build_cid:/usr/local/bin/kran-api" "$BIN_NEW"
  podman rm "$build_cid" >/dev/null
  chmod +x "$BIN_NEW"
  vendor_runtime_libs "localhost/kran-api:$REVID"
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
  # `--check` keluar 1 untuk dua hal yang berbeda (D-040): migrasi **tertunda** (normal saat deploy —
  # justru itu yang mau diterapkan) dan migrasi yang **isinya berubah** (drift: berkas yang sudah
  # diterapkan diubah, berarti DB dan repo tidak lagi sinkron). Hanya yang kedua membatalkan deploy.
  # Skrip membaca angka drift dari keluarannya; keluaran yang tidak dikenal = fail-closed.
  if check_out="$(KRAN_DATABASE_URL="$GATE_DB_URL" "$MIGRATE_BIN" --role=migrate --check 2>&1)"; then
    log "    migrasi --check bersih"
  else
    drift="$(sed -nE 's/.*, ([0-9]+) isinya berubah.*/\1/p' <<<"$check_out" | head -1)"
    case "${drift:-}" in
      "")
        log "$check_out"
        die "migrasi --check gagal dengan keluaran tak dikenal (gate fail-closed)" ;;
      0)
        log "    migrasi tertunda (normal saat deploy); lanjut --up" ;;
      *)
        log "$check_out"
        die "$drift migrasi yang sudah diterapkan berubah isinya (drift) — deploy dibatalkan" ;;
    esac
  fi
  log "==> MIGRATION GATE: --up"
  KRAN_DATABASE_URL="$GATE_DB_URL" "$MIGRATE_BIN" --role=migrate --up || die "migrasi --up gagal"
else
  log "==> migrasi tidak berubah; gate dilewati"
fi

# Tukar biner gate (lama -> .prev) hanya setelah gate lolos. Layanan tidak memakai biner ini lagi.
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
log "==> restart kran-api & kran-worker"
systemctl --user daemon-reload
systemctl --user restart kran-api
systemctl --user restart kran-worker

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
  # Layanan = container: kembalikan image sebelumnya, lalu restart.
  if podman image exists localhost/kran-api:prev; then
    log "==> rollback image: tag localhost/kran-api:prev -> :local"
    podman tag localhost/kran-api:prev localhost/kran-api:local
  fi
  if [ -f "$BIN_PREV" ]; then
    cp -f "$BIN_PREV" "$BIN"
    chmod +x "$BIN"
  fi
  if [ -d "$APP_DIR/web.prev" ]; then
    rm -rf "$APP_DIR/web"
    mv "$APP_DIR/web.prev" "$APP_DIR/web"
  fi
  restore_units
  systemctl --user daemon-reload
  systemctl --user restart kran-api || true
  systemctl --user restart kran-worker || true
  exit 1
fi
log "==> API sehat ($HEALTH_URL OK)"

# 12. State + log (spec §21.4 #12). Journal menerima stdout via systemd webhook.
if [ -n "${NEW_REV:-}" ]; then printf '%s\n' "$NEW_REV" > "$STATE_FILE"; fi
log "Deployment completed successfully for $REPO ($REVID)"