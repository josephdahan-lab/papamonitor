#!/bin/bash
# Setup script for the monitor system.
# Run once: sudo bash ~/monitor/setup.sh
set -euo pipefail

echo "=== Monitor Setup ==="

# Install msmtp for email alerts
if ! command -v msmtp &>/dev/null; then
    echo "Installing msmtp for email alerts..."
    apt-get update -qq && apt-get install -y msmtp msmtp-mta
fi

# Install logrotate config
echo "Installing logrotate config..."
cp /home/joseph/monitor/logrotate.conf /etc/logrotate.d/pi-monitor

# Set up crontab entries for joseph
CRON_MONITOR='@reboot /home/joseph/monitor/boot_check.sh'
CRON_LOGROTATE='0 3 * * * /usr/sbin/logrotate /etc/logrotate.d/pi-monitor --state /home/joseph/monitor/state/logrotate.status'

(crontab -u joseph -l 2>/dev/null || true) | grep -v 'monitor/boot_check\|monitor/logrotate\|pi-monitor' > /tmp/cron_clean
echo "$CRON_MONITOR" >> /tmp/cron_clean
echo "$CRON_LOGROTATE" >> /tmp/cron_clean
crontab -u joseph /tmp/cron_clean
rm /tmp/cron_clean

echo ""
echo "=== Crontab updated ==="
crontab -u joseph -l

echo ""
echo "=== Next steps ==="
echo "1. Edit ~/monitor/monitor.conf — set EMAIL_TO and EMAIL_ENABLED=true"
echo "2. Configure msmtp — create ~/.msmtprc with your email provider settings:"
echo ""
echo "   Example for Gmail (use an App Password):"
echo "   ---"
echo "   defaults"
echo "   auth           on"
echo "   tls            on"
echo "   tls_trust_file /etc/ssl/certs/ca-certificates.crt"
echo "   logfile        ~/.msmtp.log"
echo ""
echo "   account        gmail"
echo "   host           smtp.gmail.com"
echo "   port           587"
echo "   from           yourname@gmail.com"
echo "   user           yourname@gmail.com"
echo "   password       YOUR_APP_PASSWORD"
echo ""
echo "   account default : gmail"
echo "   ---"
echo ""
echo "   Then: chmod 600 ~/.msmtprc"
echo "   Test: echo 'test' | msmtp your@email.com"
echo ""
echo "3. Start the monitor: nohup ~/monitor/monitor.sh &"
echo "   Or add to crontab: @reboot nohup /home/joseph/monitor/monitor.sh &"
echo ""
echo "Setup complete."
