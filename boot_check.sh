#!/bin/bash
# Run this at boot (via cron @reboot or systemd) to classify the reboot.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/monitor.conf"

mkdir -p "$STATEDIR"

LOGFILE="${LOGFILE}"
BOOT_LOG="$SCRIPT_DIR/boots.log"
ts=$(date '+%F %T')

classify_boot() {
    local prev_shutdown=""
    local classification="UNKNOWN"
    local detail=""

    # Check if there's a previous boot to compare against.
    # `journalctl --list-boots` includes a 2-line header — count only
    # data rows that start with an index number.
    local num_boots
    num_boots=$(journalctl --list-boots --no-pager 2>/dev/null | awk '/^ *-?[0-9]+ /' | wc -l)

    if (( num_boots < 2 )); then
        classification="FIRST_BOOT"
        detail="No previous boot journal available (persistent journal may be disabled)"
        printf "%s | BOOT: %s — %s\n" "$ts" "$classification" "$detail"
        return
    fi

    # Look at the end of the previous boot's journal for shutdown reason
    local prev_journal
    prev_journal=$(journalctl -b -1 -n 50 --no-pager 2>/dev/null || true)

    if echo "$prev_journal" | grep -qi "shutdown\|poweroff\|halt\|reboot.*command\|systemd.*Stopping\|systemd-shutdown"; then
        if echo "$prev_journal" | grep -qi "reboot.*command\|Rebooting\|restart"; then
            classification="USER_REBOOT"
            detail="Clean reboot detected in previous journal"
        else
            classification="USER_SHUTDOWN"
            detail="Clean shutdown/poweroff detected"
        fi
    elif echo "$prev_journal" | grep -qi "panic\|Oops\|BUG:\|watchdog.*timeout"; then
        classification="KERNEL_CRASH"
        detail=$(echo "$prev_journal" | grep -i "panic\|Oops\|BUG:\|watchdog" | tail -1)
    elif echo "$prev_journal" | grep -qi "Under-voltage\|over-temperature\|throttled"; then
        classification="POWER_ISSUE"
        detail=$(echo "$prev_journal" | grep -i "Under-voltage\|over-temperature\|throttled" | tail -1)
    else
        # Journal ends abruptly without clean shutdown markers
        local last_line
        last_line=$(journalctl -b -1 -n 1 --no-pager 2>/dev/null | tail -1)
        classification="UNEXPECTED"
        detail="No clean shutdown markers found. Likely power loss or hard crash. Last log: $last_line"
    fi

    printf "%s | BOOT: %s — %s\n" "$ts" "$classification" "$detail"
}

result=$(classify_boot)

echo "$result" >> "$LOGFILE"
echo "$result" >> "$BOOT_LOG"

# Send email alert for unexpected reboots
case "$result" in
    *KERNEL_CRASH*|*UNEXPECTED*|*POWER_ISSUE*)
        if [[ "$EMAIL_ENABLED" == "true" ]]; then
            hostname=$(hostname)
            # Match the alert subject format used by monitor.sh:
            # "[<hostname>] <description>" — host front-and-center for filtering.
            if ! printf "Subject: [%s] Unexpected reboot\n\n%s\n\nPrevious boot journal (last 30 lines):\n%s\n" \
                "$hostname" "$result" "$(journalctl -b -1 -n 30 --no-pager 2>/dev/null)" \
                | msmtp "$EMAIL_TO" 2>>"$LOGFILE"; then
                echo "$ts | WARNING: boot_check msmtp failed" >> "$LOGFILE"
            fi
        fi
        ;;
esac

echo "$ts | boot_check complete" >> "$LOGFILE"
