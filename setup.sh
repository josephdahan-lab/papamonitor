#!/bin/bash
# Setup script for the papaMonitor system.
#
# Run from inside the cloned repo:
#   sudo bash setup.sh
#
# Idempotent — safe to re-run.
set -euo pipefail

if [ "$EUID" -ne 0 ]; then
    echo "This installer needs root. Re-run with: sudo bash setup.sh" >&2
    exit 1
fi

REPO_DIR="$(cd "$(dirname "$0")" && pwd)"
TARGET_USER="${SUDO_USER:-$USER}"
if [ "$TARGET_USER" = "root" ]; then
    echo "Refusing to install for root — run via 'sudo' as a regular user." >&2
    exit 1
fi
TARGET_HOME="$(getent passwd "$TARGET_USER" | cut -d: -f6)"

echo "═══════════════════════════════════════════════════"
echo "  papaMonitor installer"
echo "    repo:  $REPO_DIR"
echo "    user:  $TARGET_USER  (home: $TARGET_HOME)"
echo "═══════════════════════════════════════════════════"
echo

# ── 1. Install msmtp for email alerts (if not present) ─────────────────────
if ! command -v msmtp &>/dev/null; then
    echo "[1/5] Installing msmtp for email alerts..."
    apt-get update -qq && apt-get install -y msmtp msmtp-mta
else
    echo "[1/5] msmtp already installed — skipping."
fi

# ── 2. Enable persistent journaling ───────────────────────────────────────
# Without /var/log/journal, the journal lives in /run and disappears on
# reboot, which means boot_check can never see what happened before.
if [ ! -d /var/log/journal ]; then
    echo "[2/5] Enabling persistent systemd journal..."
    mkdir -p /var/log/journal
    systemd-tmpfiles --create --prefix /var/log/journal
    systemctl restart systemd-journald
else
    echo "[2/5] Persistent journal already enabled — skipping."
fi

# ── 3. Install logrotate config ────────────────────────────────────────────
echo "[3/5] Installing logrotate config..."
sed "s|/home/joseph/monitor|$REPO_DIR|g; s|/home/joseph/papaframe|$TARGET_HOME/papaframe|g" \
    "$REPO_DIR/logrotate.conf" > /etc/logrotate.d/pi-monitor

# ── 4. Install systemd units ──────────────────────────────────────────────
echo "[4/5] Installing systemd units..."
for unit in papamonitor.service papamonitor-web.service papamonitor-boot-check.service; do
    sed "s|/home/joseph/monitor|$REPO_DIR|g; s|User=joseph|User=$TARGET_USER|g; s|crontab -u joseph|crontab -u $TARGET_USER|g; s|HOME=/home/joseph|HOME=$TARGET_HOME|g" \
        "$REPO_DIR/$unit" > "/etc/systemd/system/$unit"
done
systemctl daemon-reload
systemctl enable --now papamonitor papamonitor-web papamonitor-boot-check
# boot-check is one-shot — re-run it now so the current boot gets classified
# without waiting for the next reboot.
systemctl start papamonitor-boot-check || true

# ── 5. Daily logrotate via cron ────────────────────────────────────────────
echo "[5/5] Setting up logrotate cron job..."
CRON_LOGROTATE="0 3 * * * /usr/sbin/logrotate /etc/logrotate.d/pi-monitor --state $REPO_DIR/state/logrotate.status"
(crontab -u "$TARGET_USER" -l 2>/dev/null || true) | grep -v 'pi-monitor' > /tmp/cron_clean
echo "$CRON_LOGROTATE" >> /tmp/cron_clean
crontab -u "$TARGET_USER" /tmp/cron_clean
rm /tmp/cron_clean

echo
echo "═══════════════════════════════════════════════════"
echo "  Done."
echo "═══════════════════════════════════════════════════"
echo
echo "=== Status ==="
systemctl is-active papamonitor papamonitor-web || true
echo
echo "=== Next steps ==="
echo "1. Configure msmtp (if not done yet):"
echo "     sudo nano /etc/msmtprc"
echo "   Test:  echo 'test' | msmtp your@email.com"
echo "2. Edit monitor.conf thresholds (optional):"
echo "     nano $REPO_DIR/monitor.conf"
echo "3. Open the dashboard at http://$(hostname -I | awk '{print $1}'):8088"
echo "   The Settings card lets you toggle email alerts and tune thresholds"
echo "   without a restart."
echo
echo "Logs:  journalctl -u papamonitor -f"
echo "       tail -f $REPO_DIR/monitor.log"
