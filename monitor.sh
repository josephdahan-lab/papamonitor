#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/monitor.conf"

mkdir -p "$STATEDIR"

# --- helpers ---

get_temp() {
    vcgencmd measure_temp 2>/dev/null | grep -oP '[0-9.]+'
}

get_mem() {
    free -m | awk '/Mem/{printf "%d %d %.0f", $3, $2, $3/$2*100}'
}

get_cpu_load() {
    awk '{print $1}' /proc/loadavg
}

get_cpu_percent() {
    top -bn2 -d0.5 | grep '%Cpu' | tail -1 | awk '{print 100 - $8}'
}

get_disk() {
    df / | awk 'NR==2{gsub(/%/,"",$5); printf "%s %s %s", $5, $3, $4}'
}

get_wifi() {
    iwconfig wlan0 2>/dev/null | awk -F= '/Signal level/{print $3+0}'
}

send_alert() {
    local subject="$1"
    local body="$2"
    local alert_key="$3"

    echo "$(date '+%F %T') | ALERT: $subject" >> "$LOGFILE"

    if [[ "$EMAIL_ENABLED" != "true" ]]; then
        return
    fi

    local cooldown_file="$STATEDIR/alert_${alert_key}"
    if [[ -f "$cooldown_file" ]]; then
        local last_sent
        last_sent=$(cat "$cooldown_file")
        local now
        now=$(date +%s)
        if (( now - last_sent < EMAIL_COOLDOWN )); then
            return
        fi
    fi

    local hostname
    hostname=$(hostname)
    # Send email; tolerate failures (bad config, network down, etc) so a
    # single hiccup doesn't kill the monitor loop under `set -e`. The
    # hostname goes in the subject + body so the recipient can tell which
    # Pi the alert came from (the SMTP From stays as msmtprc's user).
    if printf "Subject: [%s] %s\n\n%s\n\nHost:      %s\nTimestamp: %s\n" \
        "$hostname" "$subject" "$body" "$hostname" "$(date)" \
        | msmtp "$EMAIL_TO" 2>>"$LOGFILE"; then
        date +%s > "$cooldown_file"
    else
        echo "$(date '+%F %T') | WARNING: msmtp failed for alert $alert_key" >> "$LOGFILE"
    fi
}

# --- main loop ---

echo "$(date '+%F %T') | monitor started (pid $$)" >> "$LOGFILE"

NUM_CORES=$(nproc)

while true; do
    ts=$(date '+%F %T')
    temp=$(get_temp)
    read -r mem_used mem_total mem_pct <<< "$(get_mem)"
    cpu_load=$(get_cpu_load)
    cpu_pct=$(get_cpu_percent)
    read -r disk_pct disk_used disk_avail <<< "$(get_disk)"
    wifi_signal=$(get_wifi)
    uptime_str=$(uptime -p)

    printf "%s | temp=%s°C | cpu=%s%% load=%s | mem=%s/%sMB (%s%%) | disk=%s%% (avail %sK) | wifi=%sdBm | %s\n" \
        "$ts" "$temp" "$cpu_pct" "$cpu_load" \
        "$mem_used" "$mem_total" "$mem_pct" \
        "$disk_pct" "$disk_avail" \
        "$wifi_signal" "$uptime_str" >> "$LOGFILE"

    # --- threshold checks ---

    if awk "BEGIN{exit !($temp >= $TEMP_CRIT)}"; then
        send_alert "CRITICAL temperature ${temp}°C" \
            "CPU temperature has reached ${temp}°C (threshold: ${TEMP_CRIT}°C).\nThis may cause thermal throttling or damage." \
            "temp_crit"
    elif awk "BEGIN{exit !($temp >= $TEMP_WARN)}"; then
        send_alert "High temperature ${temp}°C" \
            "CPU temperature is ${temp}°C (warning threshold: ${TEMP_WARN}°C)." \
            "temp_warn"
    fi

    if (( mem_pct >= MEM_WARN )); then
        send_alert "High memory usage ${mem_pct}%" \
            "Memory: ${mem_used}/${mem_total}MB (${mem_pct}%).\nTop processes by memory:\n$(ps aux --sort=-%mem | head -6)" \
            "mem_warn"
    fi

    if (( disk_pct >= DISK_CRIT )); then
        send_alert "CRITICAL disk usage ${disk_pct}%" \
            "Root partition is ${disk_pct}% full.\nLargest dirs in /home:\n$(du -sh /home/*/ 2>/dev/null | sort -rh | head -5)" \
            "disk_crit"
    elif (( disk_pct >= DISK_WARN )); then
        send_alert "High disk usage ${disk_pct}%" \
            "Root partition is ${disk_pct}% full (warning: ${DISK_WARN}%)." \
            "disk_warn"
    fi

    if awk "BEGIN{exit !($cpu_load >= $NUM_CORES * $CPU_LOAD_WARN)}"; then
        send_alert "High CPU load ${cpu_load}" \
            "1-min load average is ${cpu_load} on ${NUM_CORES} cores.\nTop processes:\n$(ps aux --sort=-%cpu | head -6)" \
            "cpu_warn"
    fi

    if awk "BEGIN{exit !($wifi_signal <= $WIFI_WARN)}"; then
        send_alert "Weak WiFi signal ${wifi_signal}dBm" \
            "WiFi signal strength is ${wifi_signal}dBm (threshold: ${WIFI_WARN}dBm)." \
            "wifi_warn"
    fi

    # --- connectivity watchdog ---

    if ! ping -c 2 -W 5 "$ROUTER" > /dev/null 2>&1; then
        echo "$ts | WARNING: router unreachable, restarting wlan0" >> "$LOGFILE"
        send_alert "Network down — restarting WiFi" \
            "Router $ROUTER unreachable. Cycling wlan0." \
            "net_down"
        ip link set wlan0 down 2>>"$LOGFILE" || \
            echo "$ts | WARNING: failed to bring wlan0 down" >> "$LOGFILE"
        sleep 5
        ip link set wlan0 up 2>>"$LOGFILE" || \
            echo "$ts | WARNING: failed to bring wlan0 up" >> "$LOGFILE"
        sleep 15
    fi

    sleep "$INTERVAL"
done
