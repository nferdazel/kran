#!/usr/bin/env bash
# O-092: alert untuk KRAN — `/readyz` tidak sehat dan event outbox DEAD.
#
# Kenapa terpisah dari `system-health.sh`: skrip itu hanya mengirim heartbeat metrik host ke fond.
# Probe `/readyz` KRAN punya arti sendiri (DB, migrasi, realtime, worker, DEAD) dan harus memberi
# alarm saat berubah, bukan hanya menyimpan angka.
#
# Notifikasi: `send_tg` dari /usr/local/sbin/tg-notify.sh (kanal yang sama dengan backup).
# Anti-spam: kirim saat status **berubah**, lalu ulangi tiap 6 jam selama masih bermasalah.
# `--dry-run` mencetak pesan tanpa mengirim.
set -uo pipefail

HEALTH_URL="${KRAN_HEALTH_URL:-http://127.0.0.1:8095/readyz}"
STATE_DIR="${XDG_STATE_HOME:-$HOME/.local/state}/kran-alert"
STATE_FILE="$STATE_DIR/last"
REPEAT_SECONDS="${KRAN_ALERT_REPEAT_SECONDS:-21600}" # 6 jam
DRY_RUN=0
[ "${1:-}" = "--dry-run" ] && DRY_RUN=1

mkdir -p "$STATE_DIR"

if [ -r /usr/local/sbin/tg-notify.sh ]; then
  # shellcheck disable=SC1091
  . /usr/local/sbin/tg-notify.sh
fi

notify() {
  local message="$1"
  if [ "$DRY_RUN" -eq 1 ]; then
    printf 'DRY: %s\n' "$message"
    return 0
  fi
  if declare -F send_tg >/dev/null 2>&1; then
    send_tg "$message" || printf '[kran-alert] gagal kirim: %s\n' "$message" >&2
  else
    printf '[kran-alert] tg-notify tidak tersedia: %s\n' "$message" >&2
  fi
}

dead_count() {
  podman exec qouver-postgres psql -U qouver -d kran -tAc \
    "select count(*) from platform.outbox where status = 'DEAD'" 2>/dev/null | tr -d '[:space:]'
}

http_body="$(curl -sS -m 10 -w '\n%{http_code}' "$HEALTH_URL" 2>/dev/null)"
curl_rc=$?
code="$(tail -n1 <<<"$http_body" 2>/dev/null)"
json="$(sed '$d' <<<"$http_body" 2>/dev/null)"
[ -n "$code" ] || code="000"
dead="$(dead_count)"
[ -n "$dead" ] || dead="?"

failing=""
if [ "$curl_rc" -ne 0 ] || [ "$code" != "200" ]; then
  failing="$(python3 - "$json" <<'PY' 2>/dev/null
import json, sys
try:
    data = json.loads(sys.argv[1])
except Exception:
    print("")
    raise SystemExit
parts = [f'{c.get("name")}={c.get("detail","gagal")}'
         for c in data.get("checks", []) if c.get("status") != "ok"]
print("; ".join(parts))
PY
)"
  failing="${failing:-tidak ada detail}"
fi

if [ "$code" = "200" ] && [ "$dead" = "0" ]; then
  status="ok"
  message="KRAN OK: /readyz 200, outbox DEAD 0"
else
  status="bad"
  message="KRAN ALERT: /readyz HTTP ${code}${failing:+ ($failing)}; outbox DEAD ${dead}"
fi

now="$(date +%s)"
previous=""; previous_at=0
if [ -f "$STATE_FILE" ]; then
  read -r previous previous_at < "$STATE_FILE" || true
fi

should_send=0
if [ "$status" != "$previous" ]; then
  should_send=1
elif [ "$status" = "bad" ] && [ $((now - ${previous_at:-0})) -ge "$REPEAT_SECONDS" ]; then
  should_send=1
fi

if [ "$DRY_RUN" -eq 1 ]; then
  printf 'DRY: status=%s kirim=%s pesan=%s\n' "$status" "$should_send" "$message"
elif [ "$should_send" -eq 1 ]; then
  notify "$message"
  printf '%s %s\n' "$status" "$now" > "$STATE_FILE"
fi

if [ "$status" = "ok" ] && [ "$should_send" -eq 0 ]; then
  # Tetap simpan status sehat supaya transisi berikutnya terdeteksi.
  printf '%s %s\n' "$status" "$now" > "$STATE_FILE"
fi

printf '[%s] status=%s code=%s dead=%s send=%s\n' \
  "$(date '+%Y-%m-%d %H:%M:%S')" "$status" "$code" "$dead" "$should_send"
