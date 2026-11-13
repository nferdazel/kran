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
# Unit quadlet user (podman); dipasang dari repo oleh `sync_units` **setelah** gate lolos.
UNIT_DIR="${KRAN_UNIT_DIR:-$HOME/.config/containers/systemd}"

mkdir -p "$APP_DIR/logs"
log() { printf '[%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*" | tee -a "$LOG"; }
die() { log "ERROR: $*"; exit 1; }

# OPS-11 (T-133): batas waktu gate kesehatan. Sebelumnya 15 percobaan × (3 dtk timeout + 2 dtk
# jeda) = hingga 75 dtk, melewati batas spec §21.4 (30–60 dtk) yang justru mencegah container
# rusak menahan deploy. Sekarang deadline total 60 dtk; percobaan hanya dijalankan selama sisa
# waktu masih ada, jadi angka ini adalah batas nyata, bukan sekadar rata-rata.
HEALTH_GATE_SECONDS="${KRAN_HEALTH_GATE_SECONDS:-60}"
wait_healthy() {
  local deadline=$((SECONDS + HEALTH_GATE_SECONDS))
  while [ "$SECONDS" -lt "$deadline" ]; do
    if curl -fsS --max-time 3 "$HEALTH_URL" >/dev/null 2>&1; then
      return 0
    fi
    sleep 2
  done
  return 1
}

# Gerbang CI (D-178): deploy hanya untuk commit yang benar-benar hijau di GitHub Actions.
# Push ke `main` memicu CI dan webhook **bersamaan**, jadi webhook tiba jauh sebelum CI selesai.
# Tanpa gerbang ini commit merah tetap ter-deploy: 1 Nov 2026 build web mati di host (Node 26 tanpa
# corepack) sementara CI hijau, API naik, web tertinggal 6 hari tanpa sinyal apa pun.
#
# Nama check di bawah = nama job di `.github/workflows/ci.yml`. Mengganti nama job tanpa
# memperbarui daftar ini membuat gate gagal-closed (timeout), bukan diam-diam lolos.
CI_EXPECTED='Nim (check + unit/property test)
DB (integrasi, Postgres 18)
Web (svelte-check + axe + Playwright)
Security (gitleaks)'

# Hanya `success` yang hijau: `skipped`/`neutral` = check tidak berjalan, dan check yang hilang
# selamanya (job dihapus/dinonaktifkan) juga tidak boleh lolos. Satu nama dinilai dari run
# terbaru, karena re-run bisa meninggalkan beberapa run untuk satu check.
CI_GATE_PY=$(cat <<'PY'
import json, os, sys

expected = [n for n in os.environ.get("EXPECTED_CI_CHECKS", "").splitlines() if n]
payload = json.load(sys.stdin)
runs = payload.get("check_runs") or []

newest = {}
for run in runs:
    name = run.get("name") or ""
    if name not in expected:
        continue
    key = (run.get("started_at") or "", run.get("id") or 0)
    cur = newest.get(name)
    if cur is None or key > (cur.get("started_at") or "", cur.get("id") or 0):
        newest[name] = run

pending, failed = [], []
for name in expected:
    run = newest.get(name)
    if run is None or run.get("status") != "completed":
        pending.append(name)
    elif run.get("conclusion") != "success":
        failed.append("%s=%s" % (name, run.get("conclusion")))

if failed:
    print("FAILED " + ", ".join(failed))
elif pending:
    print("PENDING " + ", ".join(pending))
else:
    print("OK")
PY
)

ci_gate() { # ci_gate <rev>
  local rev="$1"
  if [ "${KRAN_SKIP_CI_GATE:-0}" = "1" ]; then
    log "==> WARN: GERBANG CI DILEWATI (KRAN_SKIP_CI_GATE=1) — hanya untuk pemulihan darurat"
    return 0
  fi

  # CI tidak berjalan untuk perubahan dokumen (`paths-ignore` di ci.yml). Menunggu check yang
  # tidak akan pernah muncul hanya menghabiskan batas waktu; deploy tetap jalan karena tidak ada
  # yang dibangun ulang.
  local code_changes
  code_changes="$(printf '%s\n' "$CHANGED_FILES" | grep -vE '^(docs/|.*\.md$)' | grep -v '^$' || true)"
  if [ -z "$code_changes" ]; then
    log "==> GERBANG CI: dilewati (hanya dokumen berubah, CI juga tidak berjalan)"
    return 0
  fi

  local repo="${KRAN_GITHUB_REPO:-nferdazel/kran}"
  # 1800, bukan 900: deploy pertama yang memakai gerbang ini menunggu 14 menit 04 detik (Nim, Web,
  # Security selesai lebih dulu; DB yang menentukan). Batas 15 menit membuat deploy kedua yang
  # kebetulan sedikit lebih lambat gagal hanya karena waktu, bukan karena CI merah.
  local wait_seconds="${KRAN_CI_WAIT_SECONDS:-1800}"
  local api="https://api.github.com/repos/${repo}/commits/${rev}/check-runs?per_page=100"
  local auth=()
  # Repo ini publik, jadi token opsional (batas 60 permintaan/jam tanpa token). Kalau ada,
  # dipakai — batasnya lebih longgar dan tidak bergantung pada IP bersama.
  if [ -n "${KRAN_GITHUB_TOKEN:-}" ]; then
    auth=(-H "Authorization: Bearer ${KRAN_GITHUB_TOKEN}")
  fi
  if ! command -v python3 >/dev/null 2>&1; then
    die "GERBANG CI: python3 tidak ada di host — pasang python3 atau KRAN_SKIP_CI_GATE=1 (darurat)"
  fi

  log "==> GERBANG CI: menunggu ${wait_seconds}s untuk ${rev:0:12} di ${repo}"
  local deadline=$((SECONDS + wait_seconds))
  local body_file head_file code etag verdict
  local rate_reset rate_resets=0 wait_reset
  body_file="$(mktemp)"
  head_file="$(mktemp)"
  # shellcheck disable=SC2064  # path temp sengaja di-resolve sekarang.
  trap "rm -f '$body_file' '$head_file'" RETURN
  etag=""
  while :; do
    # Tanpa token, batas GitHub hanya 60 permintaan/jam per IP — dan 45 poll per deploy akan
    # menghabiskannya. Permintaan bersyarat (`If-None-Match`) yang dijawab 304 **tidak** dihitung,
    # jadi poll berikutnya gratis selama tidak ada check-run baru.
    if [ -n "$etag" ]; then
      code="$(curl -sS --max-time 20 "${auth[@]}" \
        -H "Accept: application/vnd.github+json" -H "If-None-Match: $etag" \
        -D "$head_file" -o "$body_file" -w '%{http_code}' "$api")" ||
        die "GERBANG CI: gagal membaca check-run dari GitHub API (${repo}); deploy dibatalkan"
    else
      code="$(curl -sS --max-time 20 "${auth[@]}" \
        -H "Accept: application/vnd.github+json" \
        -D "$head_file" -o "$body_file" -w '%{http_code}' "$api")" ||
        die "GERBANG CI: gagal membaca check-run dari GitHub API (${repo}); deploy dibatalkan"
    fi

    case "$code" in
      200)
        etag="$(sed -n 's/^[Ee][Tt][Aa][Gg]: *//p' "$head_file" | tr -d '\r' | head -1)"
        verdict="$(EXPECTED_CI_CHECKS="$CI_EXPECTED" python3 -c "$CI_GATE_PY" <"$body_file")" ||
          die "GERBANG CI: jawaban GitHub tidak bisa dibaca (fail-closed)"
        ;;
      304)
        # Tidak ada perubahan sejak poll terakhir: keputusan sebelumnya masih berlaku.
        verdict="${verdict:-PENDING belum ada check-run}"
        ;;
      *)
        # 403/429 hampir selalu kuota IP (batas 60/jam tanpa token), bukan commit yang salah.
        # Menunggu sampai `X-RateLimit-Reset` lebih jujur daripada gagal: reset diumumkan GitHub,
        # dan deploy ini memang asinkron. Sekali saja, dan hanya bila resetnya masih di dalam
        # anggaran tunggu — kalau tidak, gagal dengan sebab yang bisa ditindaklanjuti.
        rate_reset="$(sed -n 's/^[Xx]-[Rr]ate[Ll]imit-[Rr]eset: *//p' "$head_file" | tr -d '\r' | head -1)"
        if [ "$code" = "403" ] || [ "$code" = "429" ]; then
          case "$rate_reset" in '' | *[!0-9]*) rate_reset="" ;; esac
          if [ "$rate_resets" -eq 0 ] && [ -n "$rate_reset" ] && [ "$rate_reset" -gt "$(date +%s)" ] &&
            [ $((rate_reset - $(date +%s))) -le "$wait_seconds" ]; then
            rate_resets=1
            wait_reset=$((rate_reset - $(date +%s) + 5))
            log "==> GERBANG CI: kuota GitHub API habis (HTTP $code); tunggu ${wait_reset}s sampai reset"
            sleep "$wait_reset"
            etag=""
            deadline=$((SECONDS + wait_seconds))
            continue
          fi
          die "GERBANG CI: kuota GitHub API habis (HTTP $code; reset ${rate_reset:-tidak diketahui}) — isi KRAN_GITHUB_TOKEN di $ENV_FILE atau tunggu reset; commit ini TIDAK di-deploy"
        fi
        die "GERBANG CI: GitHub API menjawab HTTP $code untuk ${repo}; deploy dibatalkan (fail-closed)"
        ;;
    esac

    case "$verdict" in
      OK)
        log "==> GERBANG CI: semua check hijau"
        return 0
        ;;
      FAILED*)
        die "GERBANG CI: ${verdict#FAILED } — commit ini tidak di-deploy"
        ;;
      PENDING*) : ;;
      *)
        die "GERBANG CI: jawaban tidak dikenal: $verdict (fail-closed)"
        ;;
    esac

    if [ "$SECONDS" -ge "$deadline" ]; then
      die "GERBANG CI: timeout ${wait_seconds}s, masih menunggu: ${verdict#PENDING }"
    fi
    sleep 20
  done
}

# Konfigurasi aplikasi (termasuk KRAN_DATABASE_URL/KEK). Unit systemd memuatnya lewat
# EnvironmentFile, tetapi jalur hook (webhook.service) tidak mewarisi env itu — deploy dari push
# gagal di migration gate dengan "KRAN_DATABASE_URL kosong" (ditemukan di T-045, 16 Okt 2026).
# Karena itu skrip ini yang memuatnya; nilai yang tidak ada di berkas (mis. KRAN_HEALTH_URL dari
# drop-in webhook) tetap dari lingkungan.
ENV_FILE="${KRAN_ENV_FILE:-$APP_DIR/env/kran-prod.env}"
if [ -f "$ENV_FILE" ]; then
  # OPS-16 (T-133): berkas ini memuat kredensial DB dan path KEK. Berkas yang terbaca pengguna
  # lain adalah kebocoran, bukan urusan kenyamanan — jadi diperiksa **sebelum** di-source, bukan
  # sesudah isinya masuk ke lingkungan proses. Owner boleh root (deploy dari systemd) atau user
  # yang menjalankan skrip ini.
  env_mode="$(stat -c '%a' "$ENV_FILE" 2>/dev/null || echo '')"
  if [ -z "$env_mode" ]; then
    log "==> WARN: mode $ENV_FILE tidak terbaca (stat tidak tersedia) — pemeriksaan izin dilewati"
  elif [ "$env_mode" != "600" ] && [ "$env_mode" != "400" ]; then
    die "mode $ENV_FILE = $env_mode (harus 600/400): kredensial DB/KEK terbaca pengguna lain"
  fi
  env_owner="$(stat -c '%U' "$ENV_FILE" 2>/dev/null || echo '')"
  if [ -n "$env_owner" ] && [ "$env_owner" != "$(id -un)" ] && [ "$env_owner" != "root" ]; then
    die "$ENV_FILE dimiliki $env_owner, bukan $(id -un)/root"
  fi
  set -a
  # shellcheck disable=SC1090
  . "$ENV_FILE"
  set +a
  log "==> env aplikasi dimuat: $ENV_FILE (mode $env_mode, owner ${env_owner:-?})"
fi

# D-204/K-02: kode sengaja **tidak** punya default rentang proxy. Tanpa `KRAN_TRUSTED_PROXY_CIDRS`
# API gagal-tertutup: header `X-Forwarded-For` diabaikan, kolom `inet` audit berisi alamat gateway,
# dan pembatas login menjadi satu ember untuk semua klien. Itu aman tetapi buta, dan buta pada IP
# audit adalah persis yang membuat K-01 sulit ditelusuri — jadi keadaan itu harus berisik.
if [ -z "${KRAN_TRUSTED_PROXY_CIDRS:-}" ]; then
  log "==> WARN: KRAN_TRUSTED_PROXY_CIDRS kosong — IP audit akan berisi alamat gateway podman dan" \
      "pembatas login menjadi satu ember. Isi dengan gateway bridge, mis. 10.89.0.1/32"
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

# O-010: migrasi/seed memakai role **owner**, runtime memakai role aplikasi tanpa hak tulis audit.
# URL owner disimpan terpisah supaya tidak ikut dimuat unit API/worker (EnvironmentFile).
# Tanpa berkas ini perilaku lama dipertahankan (satu URL), jadi deploy aman sebelum role dipisah.
MIGRATE_ENV_FILE="${KRAN_MIGRATE_ENV_FILE:-$APP_DIR/env/kran-migrate.env}"
MIGRATE_DB_URL="$KRAN_DATABASE_URL"
if [ -f "$MIGRATE_ENV_FILE" ]; then
  MIGRATE_DB_URL="$(sed -n 's/^KRAN_DATABASE_URL=//p' "$MIGRATE_ENV_FILE" | head -1)"
  [ -n "$MIGRATE_DB_URL" ] || die "KRAN_DATABASE_URL kosong di $MIGRATE_ENV_FILE"
  log "==> migrasi memakai role owner dari $MIGRATE_ENV_FILE"
fi
MIGRATE_DB_URL_HOST="${MIGRATE_DB_URL//@qouver-postgres:/@127.0.0.1:}"

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
if [ "$REF" != "refs/heads/main" ]; then
  log "==> skip: ref=${REF:-<kosong>} (bukan refs/heads/main)"
  exit 0
fi

# 2. Lock (spec §21.4 #2): satu deploy pada satu waktu.
exec 9>"$APP_DIR/.deploy.lock"
# OPS-1 (T-131): keluar 0 berarti webhook melihat "deploy sukses" padahal commit ini **tidak
# pernah** di-deploy, jadi kegagalan harus jelas. Tapi `-n` (langsung gagal) ikut membuang commit
# yang sah saat beberapa push datang beruntun: deploy kedua berhenti, `main` tertinggal, dan tidak
# ada yang memicu ulang. Karena itu menunggu (default 900 dtk, D-178) lalu gagal dengan pesan yang
# menyebut commit-nya.
LOCK_WAIT="${KRAN_DEPLOY_LOCK_WAIT:-1200}"
if ! flock -w "$LOCK_WAIT" 9; then
  log "==> ERROR: deploy lain masih berjalan setelah ${LOCK_WAIT}s (lock $APP_DIR/.deploy.lock); commit ini TIDAK di-deploy"
  exit 1
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
# ID image yang kehilangan tag `:prev` pada deploy ini; diisi saat build (lihat di bawah).
OLD_PREV_IMAGE_ID=""
# 1 bila host ini sudah punya image `:local` sebelum build, jadi `:prev` wajib ada dan berbeda
# sebagai target rollback setelah deploy. Host baru (belum pernah build) tidak punya apa pun
# untuk di-rollback, jadi syarat ini tidak berlaku di sana.
PREV_TARGET_REQUIRED=0

# OPS-10 (T-131): HMAC GitHub menutup **body**, bukan waktu kirim, jadi satu delivery sah bisa
# diputar ulang. Pertahanannya bukan di webhook melainkan di sini: rev yang sama dengan yang sudah
# ter-deploy tidak membangun/mengulang apa pun. `KRAN_FORCE_DEPLOY=1` untuk deploy ulang yang
# memang disengaja (mis. setelah mengubah env di server).
if [ "$IS_FIRST" -eq 0 ] && [ -f "$STATE_FILE" ] && [ "$(cat "$STATE_FILE")" = "$NEW_REV" ] &&
   [ "${KRAN_FORCE_DEPLOY:-0}" != "1" ]; then
  log "==> skip: rev $REVID sudah ter-deploy (delivery duplikat/replay; KRAN_FORCE_DEPLOY=1 untuk paksa)"
  exit 0
fi

ci_gate "$NEW_REV"

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

# `sync_units` sengaja **tidak** dipanggil di sini: memasang unit baru sebelum FREEZE/MIGRATION gate
# membuat `die` meninggalkan unit yang belum tentu cocok dengan image yang berjalan (OPS-5,
# T-131). Pemasangan terjadi setelah gate lolos, tepat sebelum restart.

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
# Keputusan diambil dari **kode keluar**, bukan teks: keluaran manusia bisa berubah tanpa
# disadari, sedangkan kode keluar adalah kontrak `ctl` (0 = idle, selain 0 = tahan). Biner lama
# yang belum mengenal perintah ini keluar 3 → tetap menahan deploy (fail-closed).
if [ -x "$BIN" ]; then
  set +e
  freeze_out="$(KRAN_DATABASE_URL="$GATE_DB_URL" "$BIN" --role=ctl daycloser-status 2>&1)"
  freeze_code=$?
  set -e
  if [ "$freeze_code" -ne 0 ]; then
    log "==> FREEZE: day-close tidak idle (kode keluar $freeze_code); deploy dibatalkan"
    log "    status: $freeze_out"
    exit 0
  fi
else
  log "==> WARN: $BIN belum ada; FREEZE GATE dilewati pada deploy pertama"
fi

# 5 (rebuild selektif) diterapkan lewat kondisi grep per komponen di bawah.
# 6. Pre-migration dump bila ada perubahan migrasi (spec §21.4 #6).
MIGRATIONS_CHANGED=0
DUMP_TAKEN=0
if [ "$IS_FIRST" -eq 1 ] || grep -qE 'migrations/' <<<"$CHANGED_FILES"; then
  MIGRATIONS_CHANGED=1
  if [ -x "$APP_DIR/scripts/backup-pre-deploy.sh" ]; then
    "$APP_DIR/scripts/backup-pre-deploy.sh" "$REVID" || die "pre-migration dump gagal; deploy dibatalkan"
    DUMP_TAKEN=1
  else
    die "scripts/backup-pre-deploy.sh belum terpasang; pre-migration dump wajib (spec §21.4 #6)"
  fi
fi

# 7. Build + ekstrak binary (spec §21.4 #7). Rebuild hanya bila input build berubah.
if [ "$IS_FIRST" -eq 1 ] || grep -qE '^(apps/api/|modules/|shared/|tools/|kran\.nimble|nimble\.lock)' <<<"$CHANGED_FILES"; then
  log "==> Build API (podman, tag :local)..."
  [ -d "$MONO_DIR/apps/api" ] || die "apps/api tidak ditemukan"
  # Konteks build = root monorepo, bukan apps/api: sumber Nim ada di shared/ + modules/ + tools/
  # (beda dari pola Skyward yang modulnya mandiri). Dockerfile-nya di apps/api/Dockerfile.
  cd "$MONO_DIR" || die "gagal masuk $MONO_DIR"
  # Simpan image sebelumnya: rollback LAYANAN memakai tag image. Biner di bawah bukan untuk
  # layanan, hanya supaya gate (FREEZE/MIGRATION) bisa menjalankan versi yang baru dibangun.
  # Image yang sekarang memegang `:prev` akan kehilangan tag setelah rotasi di bawah (rotasi
  # memindahkan `:prev` ke image `:local` saat ini). Dicatat untuk dipangkas setelah gate sukses.
  local_before="$(podman image inspect --format '{{.Id}}' localhost/kran-api:local 2>/dev/null || true)"
  if podman image exists localhost/kran-api:prev; then
    OLD_PREV_IMAGE_ID="$(podman image inspect --format '{{.Id}}' localhost/kran-api:prev 2>/dev/null || true)"
  fi
  if [ -n "$local_before" ]; then
    podman tag localhost/kran-api:local localhost/kran-api:prev 2>/dev/null || true
    # `:local` dan `:prev` bisa menunjuk image yang **sama**: deploy sukses sebelumnya, atau
    # rollback yang baru saja men-tag `:prev` -> `:local`. Rotasi di atas jadi no-op — dan itu
    # benar, `:prev` tetap image lama sementara build memindahkan `:local` ke image baru. Yang
    # salah adalah mencatat image itu untuk dipangkas: `:prev` satu-satunya pemegangnya, prune
    # menghapusnya setelah gate, dan `:prev` ikut mati (deploy v0.3.0, 12 Nov 2026 — rollback.sh
    # lalu gagal di baris 31). Tidak ada image lebih tua untuk dipangkas di kasus ini.
    if [ "${OLD_PREV_IMAGE_ID:-}" = "$local_before" ]; then
      OLD_PREV_IMAGE_ID=""
    fi
  fi
  podman build -f apps/api/Dockerfile -t localhost/kran-api:local .
  # Syarat target rollback hanya berlaku bila build benar-benar memindahkan `:local`. Build yang
  # menghasilkan ID sama (mis. konteks tidak berubah) tidak meninggalkan versi lain untuk kembali,
  # dan memaksakan `:prev` di situ akan menggagalkan deploy yang isinya cuma ops/docs.
  local_after="$(podman image inspect --format '{{.Id}}' localhost/kran-api:local 2>/dev/null || true)"
  if [ -n "$local_before" ] && [ -n "$local_after" ] && [ "$local_after" != "$local_before" ]; then
    PREV_TARGET_REQUIRED=1
  fi
  mkdir -p "$APP_DIR/bin"
  build_cid="$(podman create localhost/kran-api:local)"
  podman cp "$build_cid:/usr/local/bin/kran-api" "$BIN_NEW"
  podman rm "$build_cid" >/dev/null
  chmod +x "$BIN_NEW"
  vendor_runtime_libs localhost/kran-api:local
else
  log "==> kode API tidak berubah; build dilewati"
  # Sisa `.new` dari deploy yang gagal setelah build tidak boleh dipakai gate/swap pada deploy ini.
  if [ -f "$BIN_NEW" ]; then
    log "    hapus biner baru basi: $BIN_NEW"
    rm -f "$BIN_NEW"
  fi
fi

# 8. MIGRATION GATE (spec §21.4 #8, expand-only) memakai binary BARU, sebelum
#    binary ditukar: gagal => deploy dibatalkan dan binary lama tetap utuh.
MIGRATE_BIN="$BIN_NEW"
[ -x "$MIGRATE_BIN" ] || MIGRATE_BIN="$BIN"
[ -x "$MIGRATE_BIN" ] || die "tidak ada binary untuk migration gate"

if [ "$MIGRATIONS_CHANGED" -eq 1 ]; then
  log "==> MIGRATION GATE: --check"
  # `--check` keluar 1 untuk dua hal yang berbeda (D-040): migrasi **tertunda** (normal saat deploy —
  # justru itu yang mau diterapkan) dan migrasi yang **isinya berubah** (drift: berkas yang sudah
  # diterapkan diubah, berarti DB dan repo tidak lagi sinkron). Hanya yang kedua membatalkan deploy.
  # Skrip membaca angka drift dari keluarannya; keluaran yang tidak dikenal = fail-closed.
  if check_out="$(KRAN_DATABASE_URL="$MIGRATE_DB_URL_HOST" "$MIGRATE_BIN" --role=migrate --check 2>&1)"; then
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
  KRAN_DATABASE_URL="$MIGRATE_DB_URL_HOST" "$MIGRATE_BIN" --role=migrate --up || die "migrasi --up gagal"
else
  log "==> migrasi tidak berubah; --up dilewati"
fi

# Contract (D-040) diperiksa **setiap** deploy, bukan hanya saat repo mengubah migrasi: skema bisa
# tertinggal karena restore dump/`--down` manual. Dijalankan sebelum binary baru menerima trafik,
# hanya untuk id di allowlist repo; contract lain = fail-closed. `--check` setelah contract
# memastikan tidak ada yang tertunda.
log "==> MIGRATION GATE: contract"
if ! contract_check="$(KRAN_DATABASE_URL="$MIGRATE_DB_URL_HOST" "$MIGRATE_BIN" --role=migrate --check 2>&1)"; then
  log "$contract_check"
  die "migrate --check gagal (expand tertunda atau drift) — periksa manual dengan migrate.sh --check"
fi
pending_count="$(sed -nE 's/^  contract_pending=([0-9]+)$/\1/p' <<<"$contract_check" | tail -1)"
[ -n "${pending_count:-}" ] ||
  die "format --check tidak dikenal (contract_pending hilang) — biner ini pra-T-086; jalankan migrate --check manual, gate contract fail-closed"
if [ "$pending_count" -gt 0 ]; then
  pending_contracts="$(sed -nE 's/^  contract_ids=//p' <<<"$contract_check" | tail -1)"
  [ -n "${pending_contracts:-}" ] ||
    die "contract_pending=$pending_count tetapi contract_ids tidak ada — fail-closed"
  allow_file="$MONO_DIR/ops/migrations/contract-auto.txt"
  [ -f "$allow_file" ] || die "contract tertunda ($pending_contracts) tetapi $allow_file tidak ada"
  IFS=',' read -r -a contract_ids <<<"$pending_contracts"
  for raw_id in "${contract_ids[@]}"; do
    contract_id="${raw_id# }"
    contract_id="${contract_id% }"
    [ -n "$contract_id" ] || continue
    grep -qxF "$contract_id" "$allow_file" ||
      die "contract $contract_id tidak ada di allowlist — jalankan migrate --contract manual"
  done
  log "    contract di-allowlist: $pending_contracts"
  if [ "$DUMP_TAKEN" -eq 0 ]; then
    # Contract = DDL merusak (drop constraint/trigger) dan bisa muncul walau kode tidak berubah
    # (restore dump/--down manual): jaring rollback wajib ada sebelum dijalankan.
    log "==> pre-contract dump (wajib: contract tanpa perubahan kode)"
    [ -x "$APP_DIR/scripts/backup-pre-deploy.sh" ] ||
      die "contract tertunda tetapi scripts/backup-pre-deploy.sh tidak ada — fail-closed"
    "$APP_DIR/scripts/backup-pre-deploy.sh" "$REVID-contract" || die "pre-contract dump gagal; --contract dibatalkan"
    DUMP_TAKEN=1
  fi
  KRAN_DATABASE_URL="$MIGRATE_DB_URL_HOST" "$MIGRATE_BIN" --role=migrate --contract ||
    die "migrasi --contract gagal"
  after_contract="$(KRAN_DATABASE_URL="$MIGRATE_DB_URL_HOST" "$MIGRATE_BIN" --role=migrate --check 2>&1)" ||
    die "migrate --check gagal setelah --contract"
  sisa="$(sed -nE 's/^  contract_pending=([0-9]+)$/\1/p' <<<"$after_contract" | tail -1)"
  [ -n "${sisa:-}" ] || die "format --check setelah contract tidak dikenal — fail-closed"
  if [ "$sisa" -ne 0 ]; then
    log "$after_contract"
    die "contract masih tertunda setelah --contract (fail-closed)"
  fi
  log "    contract selesai"
else
  log "    tidak ada contract tertunda"
fi

# Tukar biner gate (lama -> .prev) hanya setelah gate lolos. Layanan tidak memakai biner ini lagi.
if [ -f "$BIN_NEW" ]; then
  if [ -f "$BIN" ]; then cp -f "$BIN" "$BIN_PREV"; fi
  mv -f "$BIN_NEW" "$BIN"
  chmod +x "$BIN"
fi

# O-090: parameter base wajib ada SEBELUM unit di-restart. Deploy me-restart worker lebih dulu,
# dan worker menolak start (exit 2) bila parameter posting belum tersemai. Berkas seed idempoten
# (`param_definitions` DO UPDATE metadata, `param_values` DO NOTHING) dan tidak memuat seed dev.
log "==> seed parameter base (idempoten)"
KRAN_DATABASE_URL="$MIGRATE_DB_URL_HOST" "$BIN" --role=migrate --root="$MONO_DIR" --seed ||
  die "seed parameter gagal — deploy dibatalkan (worker tidak di-restart dengan parameter belum lengkap)"

# 9. Web: build statis lalu swap atomik (`web.new` -> `web`, `web.prev` disimpan).
if [ "$IS_FIRST" -eq 1 ] || grep -qE '^(apps/web/|packages/)' <<<"$CHANGED_FILES"; then
  if [ -f "$MONO_DIR/apps/web/package.json" ]; then
    log "==> Build web (pnpm)..."
    cd "$MONO_DIR/apps/web" || die "gagal masuk apps/web"
    # OPS-3 (T-131): versi pnpm dipatok `packageManager` di package.json, jadi build web sama dengan
    # CI. Tanpa pin, build bisa memakai pnpm lain yang mengabaikan `minimumReleaseAge`/`allowBuilds`
    # (cooldown supply chain) — yaitu kebijakan keamanan yang justru dilewati.
    #
    # `npm exec`, bukan `corepack`: Node 25+ tidak lagi membawa corepack dan host deploy memakai
    # Node 26. Saat masih `corepack pnpm`, skrip berhenti tepat di sini dengan
    # `corepack: command not found` — API sudah ter-build, web **tidak pernah** di-swap, dan
    # deploy.log tampak "berhenti setelah Build web" karena stderr-nya hanya masuk journal webhook.
    pnpm_version="$(sed -nE 's/.*"packageManager": *"pnpm@([^"]+)".*/\1/p' "$MONO_DIR/package.json" | head -1)"
    [ -n "$pnpm_version" ] || die "package.json tidak memuat \"packageManager\" (pnpm) — deploy dibatalkan"
    log "    pnpm $pnpm_version (dari package.json)"
    npm exec --yes -- "pnpm@$pnpm_version" install --frozen-lockfile ||
      die "pnpm install (web) gagal — lihat journal webhook"
    npm exec --yes -- "pnpm@$pnpm_version" run build ||
      die "build web (pnpm) gagal — lihat journal webhook"
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

# Retensi image (T-069, OPS-2/T-131). Build **tidak pernah** membuat tag SHA: yang ada hanya
# `:local` (aktif) dan `:prev` (cadangan rollback). Karena itu pemangkas lama (`grep` tag 12-hex)
# tidak pernah menemukan apa pun — setiap deploy meninggalkan satu image dangling. Yang benar:
# sebelum build, catat ID image yang **sekarang** memegang `:prev` (image itu akan kehilangan tag
# setelah rotasi), lalu hapus ID itu setelah health gate sukses. `:local`/`:prev` tidak pernah
# disentuh, dan penghapusan terjadi setelah gate supaya target rollback tidak hilang lebih dulu.
# Gagal `rmi` (masih dipakai container berhenti) = WARN, bukan deploy gagal.
prune_previous_image() {
  local image_id="${1:-}"
  [ -n "$image_id" ] || return 0
  if podman rmi "$image_id" >/dev/null 2>&1; then
    log "==> image sebelumnya dihapus: ${image_id:0:12}"
  else
    log "==> WARN: gagal menghapus image ${image_id:0:12} (masih dipakai container?)"
  fi
}

# 9b. Pasang unit quadlet dari repo **setelah** semua gate lolos (OPS-5, T-131): unit baru hanya
# masuk disk bila image & skema sudah siap menerimanya.
log "==> pasang unit quadlet dari repo"
sync_units

# 10. Restart unit (spec §21.4 #10).
log "==> restart kran-api & kran-worker"
systemctl --user daemon-reload
systemctl --user restart kran-api
systemctl --user restart kran-worker

# 11. HEALTH GATE + auto-rollback (spec §21.4 #11): poll /readyz dengan deadline 60 dtk (OPS-11).
healthy=0
if wait_healthy; then
  healthy=1
fi

# OPS-11: `/readyz` sehat hanya membuktikan **ada** yang menjawab. Yang harus dibuktikan adalah
# bahwa yang menjawab adalah image yang baru dibangun. Container yang masih jalan dari image lama
# (restart gagal, `AutoUpdate=local` tidak terpakai) juga sehat — dan deploy akan tercatat sukses
# untuk kode yang tidak pernah berjalan.
if [ "$healthy" -eq 1 ]; then
  running_image="$(podman inspect --format '{{.Image}}' kran-api 2>/dev/null || echo '')"
  local_image="$(podman image inspect --format '{{.Id}}' localhost/kran-api:local 2>/dev/null || echo '')"
  if [ -n "$running_image" ] && [ -n "$local_image" ] && [ "$running_image" != "$local_image" ]; then
    log "==> ERROR: container kran-api berjalan dari image ${running_image:0:19}, bukan :local ${local_image:0:19}"
    healthy=0
  elif [ -z "$running_image" ] || [ -z "$local_image" ]; then
    log "==> WARN: tidak bisa membandingkan image container dengan :local (podman inspect kosong)"
  else
    log "==> revisi yang melayani = image ${local_image:0:19} (:local)"
  fi

  # Target rollback adalah bagian dari arti "deploy sukses": health gate yang hijau tanpa `:prev`
  # berarti deploy berikutnya tidak punya tempat kembali, dan rollback.sh berhenti di baris 31
  # sebelum sempat memulihkan web/biner (deploy v0.3.0, 12 Nov 2026).
  if [ "$healthy" -eq 1 ] && [ "$PREV_TARGET_REQUIRED" -eq 1 ]; then
    prev_image="$(podman image inspect --format '{{.Id}}' localhost/kran-api:prev 2>/dev/null || echo '')"
    if [ -z "$prev_image" ]; then
      log "==> ERROR: localhost/kran-api:prev tidak ada; target rollback hilang"
      healthy=0
    elif [ "$prev_image" = "$local_image" ]; then
      log "==> ERROR: :prev dan :local menunjuk image yang sama (${prev_image:0:19}); target rollback hilang"
      healthy=0
    else
      log "==> target rollback = image ${prev_image:0:19} (:prev)"
    fi
  fi
fi

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

  # OPS-4 (T-131): rollback yang tidak sehat **bukan** rollback selesai. Tanpa pemeriksaan kedua,
  # log hanya mengatakan "rollback" sementara layanan tetap mati dan tidak ada yang tahu.
  rollback_healthy=0
  if wait_healthy; then
    rollback_healthy=1
  fi
  if [ "$rollback_healthy" -eq 1 ]; then
    log "==> rollback selesai dan sehat ($HEALTH_URL OK) — deploy revision $REVID dianggap GAGAL"
  else
    log "==> ERROR: rollback juga tidak sehat ($HEALTH_URL). Butuh intervensi manual (rollback.sh, log container)."
  fi
  exit 1
fi
log "==> API sehat ($HEALTH_URL OK)"
prune_previous_image "$OLD_PREV_IMAGE_ID"

# OPS-8 (T-131): manifest rilis satu baris — rev, image yang sedang aktif, hash biner gate, waktu.
# Tag SHA sengaja tidak dipakai: retensi hanya `:local`/`:prev` (kontrak emas §3.4). Bukti rilis
# karena itu berupa catatan, bukan tumpukan image/biner per commit.
image_id="$(podman image inspect --format '{{.Id}}' localhost/kran-api:local 2>/dev/null || echo unknown)"
bin_sha="$(sha256sum "$BIN" 2>/dev/null | cut -d' ' -f1 || echo unknown)"
printf '%s %s %s %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$NEW_REV" "${image_id:0:19}" "$bin_sha" \
  >> "$APP_DIR/releases.txt"
log "==> rilis dicatat: $APP_DIR/releases.txt (rev ${REVID}, image ${image_id:0:19}, bin $bin_sha)"

# 12. State + log (spec §21.4 #12). Journal menerima stdout via systemd webhook.
if [ -n "${NEW_REV:-}" ]; then printf '%s\n' "$NEW_REV" > "$STATE_FILE"; fi
log "Deployment completed successfully for $REPO ($REVID)"