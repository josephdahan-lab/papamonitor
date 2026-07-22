#!/bin/bash
# Service watchdog — checks that all services are responding and restarts them if not.
# Called from the main monitor loop or standalone via cron/systemd.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/monitor.conf"

WATCHDOG_LOG="$SCRIPT_DIR/watchdog.log"
STATEDIR="${STATEDIR:-$SCRIPT_DIR/state}"
mkdir -p "$STATEDIR"

# Service definitions: name|port|restart_command
SERVICES=(
    "jellyfin|8096|sudo docker restart jellyfin"
    "immich|2283|cd /home/joseph/immich-app && sudo docker compose up -d"
    "papabackup|9999|cd /home/joseph/papabackup && nohup python3 app.py > /tmp/papabackup.log 2>&1 &"
    "papamonitor|8088|cd /home/joseph/monitor && nohup python3 web.py > /home/joseph/monitor/web.log 2>&1 &"
    "papastuff|80|sudo systemctl restart papastuff.service"
    "papastreams|3000|sudo systemctl restart papastreams.service"
)

MAX_RETRIES=2
CHECK_TIMEOUT=5

log() {
    echo "$(date '+%F %T') | $1" >> "$WATCHDOG_LOG"
}

check_service() {
    local name="$1"
    local port="$2"
    curl -sf --max-time "$CHECK_TIMEOUT" -o /dev/null "http://localhost:${port}/" 2>/dev/null
    return $?
}

restart_service() {
    local name="$1"
    local cmd="$2"
    log "RESTART: attempting to restart $name"
    eval "$cmd" >> "$WATCHDOG_LOG" 2>&1
    sleep 5
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
    IFS='|' read -r name port restart_cmd <<< "$entry"

    if check_service "$name" "$port"; then
        continue
    fi

    all_ok=false
    log "DOWN: $name (port $port) is not responding"

    for attempt in $(seq 1 $MAX_RETRIES); do
        log "Attempt $attempt/$MAX_RETRIES to restart $name"
        restart_service "$name" "$restart_cmd"

        if check_service "$name" "$port"; then
            log "OK: $name recovered after attempt $attempt"
            # Clear any previous alert cooldown on recovery
            rm -f "$STATEDIR/watchdog_${name}"
            all_ok=true
            break
        fi
    done

    if ! check_service "$name" "$port"; then
        log "FAILED: $name could not be restored after $MAX_RETRIES attempts"
        alert_service_down "$name"
    fi
done

if $all_ok; then
    log "All services OK"
fi
