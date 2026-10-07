#!/bin/bash
# Service watchdog — checks that all services are responding and restarts them if not.
# Called from the main monitor loop or standalone via cron/systemd.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/monitor.conf"

WATCHDOG_LOG="$SCRIPT_DIR/watchdog.log"
STATEDIR="${STATEDIR:-$SCRIPT_DIR/state}"
mkdir -p "$STATEDIR"

# Service definitions: name|port|health_path|install_path|restart_command
# Services whose install_path doesn't exist are skipped, so the same list
# works on every host (empty install_path = always check). The health path
# should be a cheap endpoint that returns 2xx/3xx when the app is really up
# (immich's container keeps port 2283 bound by docker-proxy even when the
# API worker inside is dead, so it needs the real ping endpoint).
SERVICES=(
    "jellyfin|8096|/health|/usr/lib/jellyfin|sudo systemctl restart jellyfin.service"
    "immich|2283|/api/server/ping|/home/joseph/immich-app|sudo docker restart immich_server || (cd /home/joseph/immich-app && sudo docker compose up -d)"
    "papabackup|9999|/|/home/joseph/papabackup|cd /home/joseph/papabackup && nohup python3 app.py > /tmp/papabackup.log 2>&1 &"
    "papamonitor|8088|/api/config||sudo systemctl restart papamonitor-web.service"
    "papastuff|80|/|/home/joseph/papastuff|sudo systemctl restart papastuff.service"
    "papastreams|3000|/|/home/joseph/papastreams|sudo systemctl restart papastreams.service"
    "papabookmarks|6001|/|/home/joseph/papabookmarks|sudo systemctl restart papabookmarks.service"
)

MAX_RETRIES=2
# web.py is single-threaded and /api/stats can take several seconds, so
# give services a bit of slack before declaring them down.
CHECK_TIMEOUT=10
# Time to wait after a restart before re-checking (immich takes ~30s to boot).
RESTART_GRACE=30

log() {
    echo "$(date '+%F %T') | $1" >> "$WATCHDOG_LOG"
}

check_service() {
    local port="$1"
    local path="$2"
    curl -sf --max-time "$CHECK_TIMEOUT" -o /dev/null "http://localhost:${port}${path}" 2>/dev/null
}

restart_service() {
    local name="$1"
    local cmd="$2"
    local port="$3"
    local path="$4"
    log "RESTART: attempting to restart $name"
    eval "$cmd" >> "$WATCHDOG_LOG" 2>&1
    # Poll rather than sleep a fixed time so fast services recover quickly.
    local waited=0
    while (( waited < RESTART_GRACE )); do
        sleep 5
        waited=$((waited + 5))
        check_service "$port" "$path" && return
    done
}

alert_service_down() {
    local name="$1"
    local cooldown_file="$STATEDIR/watchdog_${name}"

    if [[ -f "$cooldown_file" ]]; then
        local last_sent
        last_sent=$(cat "$cooldown_file")
        local now
        now=$(date +%s)
        if (( now - last_sent < ${EMAIL_COOLDOWN:-900} )); then
            return
        fi
    fi

    if [[ "${EMAIL_ENABLED:-false}" == "true" ]]; then
        printf "Subject: [%s] Service DOWN: %s\n\nService %s failed to respond after %d restart attempts.\n\nHost: %s\nTime: %s\n" \
            "$(hostname)" "$name" "$name" "$MAX_RETRIES" "$(hostname)" "$(date)" \
            | msmtp "$EMAIL_TO" 2>>"$WATCHDOG_LOG" && date +%s > "$cooldown_file"
    fi
}

log "=== Watchdog check started ==="

all_ok=true

for entry in "${SERVICES[@]}"; do
    IFS='|' read -r name port path install_path restart_cmd <<< "$entry"

    if [[ -n "$install_path" && ! -e "$install_path" ]]; then
        continue
    fi

    if check_service "$port" "$path"; then
        continue
    fi

    all_ok=false
    log "DOWN: $name (port $port) is not responding"

    for attempt in $(seq 1 $MAX_RETRIES); do
        log "Attempt $attempt/$MAX_RETRIES to restart $name"
        restart_service "$name" "$restart_cmd" "$port" "$path"

        if check_service "$port" "$path"; then
            log "OK: $name recovered after attempt $attempt"
            # Clear any previous alert cooldown on recovery
            rm -f "$STATEDIR/watchdog_${name}"
            all_ok=true
            break
        fi
    done

    if ! check_service "$port" "$path"; then
        log "FAILED: $name could not be restored after $MAX_RETRIES attempts"
        alert_service_down "$name"
    fi
done

if $all_ok; then
    log "All services OK"
fi
