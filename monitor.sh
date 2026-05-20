#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/monitor.conf"

mkdir -p "$STATEDIR"

# --- helpers ---

get_temp() {
    # Pi: vcgencmd reports the SoC temp directly. x86: read the warmest
    # thermal zone in /sys (covers Intel coretemp, AMD k10temp, etc).
    if command -v vcgencmd >/dev/null 2>&1; then
        vcgencmd measure_temp 2>/dev/null | grep -oP '[0-9.]+'
        return
    fi
    local hottest=0
    for z in /sys/class/thermal/thermal_zone*/temp; do
        [ -r "$z" ] || continue
        local milli
        milli=$(cat "$z" 2>/dev/null) || continue
        (( milli > hottest )) && hottest=$milli
    done
    if (( hottest > 0 )); then
        awk -v m="$hottest" 'BEGIN{printf "%.1f", m/1000}'
    fi
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

get_wifi_iface() {
    # Pick the first wireless interface (wlan0 on Pi, wlpXsY on x86, etc).
    # Returns empty if there is none (ethernet-only host).
    for iface in /sys/class/net/*; do
        [ -d "$iface/wireless" ] && { basename "$iface"; return; }
    done
}

get_wifi() {
    local iface
    iface=$(get_wifi_iface)
    [ -z "$iface" ] && return
    iwconfig "$iface" 2>/dev/null | awk -F= '/Signal level/{print $3+0}'
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
    wifi_part=""
    [ -n "$wifi_signal" ] && wifi_part="wifi=${wifi_signal}dBm | "

    printf "%s | temp=%s°C | cpu=%s%% load=%s | mem=%s/%sMB (%s%%) | disk=%s%% (avail %sK) | %s%s\n" \
        "$ts" "$temp" "$cpu_pct" "$cpu_load" \
        "$mem_used" "$mem_total" "$mem_pct" \
        "$disk_pct" "$disk_avail" \
        "$wifi_part" "$uptime_str" >> "$LOGFILE"

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

    # Only check WiFi when we actually have a wireless interface and a reading.
    if [ -n "$wifi_signal" ] && awk "BEGIN{exit !($wifi_signal <= $WIFI_WARN)}"; then
        send_alert "Weak WiFi signal ${wifi_signal}dBm" \
            "WiFi signal strength is ${wifi_signal}dBm (threshold: ${WIFI_WARN}dBm)." \
            "wifi_warn"
    fi

    # --- connectivity watchdog ---
    # If the router stops answering and we have a wireless interface, cycle
    # it. Ethernet-only hosts just get the alert without the cycle.

    if ! ping -c 2 -W 5 "$ROUTER" > /dev/null 2>&1; then
        wifi_iface=$(get_wifi_iface)
        if [ -n "$wifi_iface" ]; then
            echo "$ts | WARNING: router unreachable, restarting $wifi_iface" >> "$LOGFILE"
            send_alert "Network down — restarting WiFi" \
                "Router $ROUTER unreachable. Cycling $wifi_iface." \
                "net_down"
            ip link set "$wifi_iface" down 2>>"$LOGFILE" || \
                echo "$ts | WARNING: failed to bring $wifi_iface down" >> "$LOGFILE"
            sleep 5
            ip link set "$wifi_iface" up 2>>"$LOGFILE" || \
                echo "$ts | WARNING: failed to bring $wifi_iface up" >> "$LOGFILE"
            sleep 15
        else
            echo "$ts | WARNING: router unreachable (no wifi iface to cycle)" >> "$LOGFILE"
            send_alert "Network down" \
                "Router $ROUTER unreachable from $(hostname). No wireless interface — manual intervention needed." \
                "net_down"
        fi
    fi

    sleep "$INTERVAL"
done
