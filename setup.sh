#!/bin/bash
# Setup script for the papaMonitor system.
# Run once: sudo bash ~/monitor/setup.sh
set -euo pipefail

REPO_DIR="$(cd "$(dirname "$0")" && pwd)"

echo "=== papaMonitor setup ==="

# 1. Install msmtp for email alerts (if not present)
if ! command -v msmtp &>/dev/null; then
    echo "Installing msmtp for email alerts..."
    apt-get update -qq && apt-get install -y msmtp msmtp-mta
fi

# 2. Enable persistent journaling so boot_check has previous boots to read.
# Without /var/log/journal, the journal lives in /run and disappears on reboot,
# which means boot_check can never see what happened before.
if [ ! -d /var/log/journal ]; then
    echo "Enabling persistent systemd journal..."
    mkdir -p /var/log/journal
    systemd-tmpfiles --create --prefix /var/log/journal
    systemctl restart systemd-journald
fi

# 3. Install logrotate config
echo "Installing logrotate config..."
cp "$REPO_DIR/logrotate.conf" /etc/logrotate.d/pi-monitor

# 4. Install systemd units (monitor loop, web dashboard, boot classifier)
echo "Installing systemd units..."
cp "$REPO_DIR/papamonitor.service" /etc/systemd/system/
cp "$REPO_DIR/papamonitor-web.service" /etc/systemd/system/
cp "$REPO_DIR/papamonitor-boot-check.service" /etc/systemd/system/
systemctl daemon-reload
systemctl enable --now papamonitor papamonitor-web papamonitor-boot-check
# boot-check is one-shot — re-run it now so the current boot gets classified
# without waiting for the next reboot.
systemctl start papamonitor-boot-check

# 5. Daily logrotate via cron (joseph's crontab — runs as user)
CRON_LOGROTATE='0 3 * * * /usr/sbin/logrotate /etc/logrotate.d/pi-monitor --state /home/joseph/monitor/state/logrotate.status'
(crontab -u joseph -l 2>/dev/null || true) | grep -v 'pi-monitor' > /tmp/cron_clean
echo "$CRON_LOGROTATE" >> /tmp/cron_clean
crontab -u joseph /tmp/cron_clean
rm /tmp/cron_clean

echo ""
echo "=== Status ==="
systemctl is-active papamonitor papamonitor-web

echo ""
echo "=== Next steps ==="
echo "1. Configure msmtp: edit ~/.msmtprc with your SMTP credentials."
echo "   Test:  echo 'test' | msmtp your@email.com"
echo "2. Open the dashboard at http://$(hostname):8088 — Settings card lets"
echo "   you toggle email alerts and tune thresholds without a restart."
echo ""
echo "Setup complete."
