#!/usr/bin/env bash
# O-092: alert untuk KRAN — `/readyz` tidak sehat dan event outbox DEAD.
# O-115: ditambah probe task day-close **non-kritis** yang `FAILED`. Run tetap `COMPLETED` saat
# task seperti itu gagal, jadi tanpa probe ini tidak ada sinyal apa pun selain halaman monitor.
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

# Jangan kirim alert selama deploy. Deploy menyinkronkan repo (`git reset --hard`) SEBELUM
# `migrate --up`, sehingga API lama yang masih jalan membaca berkas migrasi baru dan `/readyz`
# melaporkan "migrasi expand tertunda" selama beberapa detik. Itu kondisi normal, bukan insiden:
# status terakhir sengaja tidak diubah supaya tidak ada pesan ALERT/OK palsu. Bila deploy gagal
# dan `/readyz` tetap 503, probe berikutnya (lock sudah lepas) mengirim alert seperti biasa.
DEPLOY_LOCK="${KRAN_DEPLOY_LOCK:-/srv/qouver/apps/kran/.deploy.lock}"
if [ -e "$DEPLOY_LOCK" ] && command -v flock >/dev/null 2>&1; then
  if exec 8>>"$DEPLOY_LOCK" && ! flock -n 8; then
    printf '[%s] status=deploy code=- dead=- tasks=- send=0 (deploy berjalan)\n' \
      "$(date '+%Y-%m-%d %H:%M:%S')"
    exit 0
  fi
fi

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

# O-115: count task `FAILED` yang `critical = false` pada run institusi `COMPLETED` terakhir
# (business_date terbesar). Run yang lebih baru dan bersih membuat probe ini kembali 0, jadi alert
# hilang sendiri tanpa operator perlu menandai apa pun.
# Keluaran satu baris: "<jumlah>|<business_date>|<task_id (code, chunk=n); ...>".
# Kosong = probe gagal (psql/podman tidak tersedia) — sama seperti `dead="?"`.
failed_tasks_probe() {
  podman exec qouver-postgres psql -U qouver -d kran -tAc "
with latest as (
  select run_id, business_date from daycloser.run
  where scope_type = 'INSTITUTION' and state = 'COMPLETED'
  order by business_date desc, finished_at desc nulls last
  limit 1
), failed as (
  select t.task_id,
         coalesce(t.error->>'code', '?') as code,
         (select count(*) from daycloser.chunk c
           where c.run_id = t.run_id and c.task_id = t.task_id) as chunks
  from daycloser.task t
  join latest l on l.run_id = t.run_id
  where t.state = 'FAILED' and t.critical = false
)
select (select count(*) from failed) || '|' ||
       coalesce((select max(business_date)::text from latest), '') || '|' ||
       coalesce((select string_agg(
                   task_id || ' (' || code ||
                   case when chunks > 0 then ', chunk=' || chunks else '' end || ')',
                   '; ' order by task_id)
                 from failed), '')
" 2>/dev/null | tr -d '\r'
}

http_body="$(curl -sS -m 10 -w '\n%{http_code}' "$HEALTH_URL" 2>/dev/null)"
curl_rc=$?
code="$(tail -n1 <<<"$http_body" 2>/dev/null)"
json="$(sed '$d' <<<"$http_body" 2>/dev/null)"
[ -n "$code" ] || code="000"
dead="$(dead_count)"
[ -n "$dead" ] || dead="?"

failed_raw="$(failed_tasks_probe)"
task_count="?"
task_date=""
task_detail=""
if [ -n "$failed_raw" ]; then
  task_count="${failed_raw%%|*}"
  rest="${failed_raw#*|}"
  task_date="${rest%%|*}"
  if [ "$rest" != "${rest#*|}" ]; then
    task_detail="${rest#*|}"
  fi
fi
case "$task_count" in
  '' | *[!0-9]*) task_count="?" ;;
esac

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

if [ "$code" = "200" ] && [ "$dead" = "0" ] && [ "$task_count" = "0" ]; then
  status="ok"
  message="KRAN OK: /readyz 200, outbox DEAD 0, task FAILED non-kritis 0"
else
  status="bad"
  message="KRAN ALERT: /readyz HTTP ${code}${failing:+ ($failing)}; outbox DEAD ${dead}; task FAILED non-kritis ${task_count}"
  if [ "$task_count" != "0" ] && [ "$task_count" != "?" ] && [ -n "$task_detail" ]; then
    message="${message} (run ${task_date}: ${task_detail})"
  fi
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

printf '[%s] status=%s code=%s dead=%s tasks=%s send=%s\n' \
  "$(date '+%Y-%m-%d %H:%M:%S')" "$status" "$code" "$dead" "$task_count" "$should_send"
