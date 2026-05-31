# papaMonitor

Lightweight system monitor for Raspberry Pi (and other Debian-based Linux).
Tracks temperature, CPU, memory, disk, WiFi signal, and network connectivity
with email alerts and a real-time web dashboard.

Designed to run alongside [PapaFrame](https://github.com/josephdahan-lab/papaframe)
but works standalone on any Pi or Linux box.

## Features

- **Temperature** — warning and critical thresholds, throttle detection
- **CPU** — usage percentage and load average
- **Memory & Swap** — usage tracking with configurable alert threshold
- **Disk** — root partition usage with two-tier alerts
- **WiFi** — signal strength monitoring with optional watchdog (auto-restarts
  the interface when the router stops responding)
- **Boot classification** — detects clean reboot, power loss, kernel crash, or
  power issues from the previous boot's journal
- **Email alerts** — via msmtp with per-issue cooldown to avoid spam
- **Web dashboard** — dark-themed, auto-refreshing, mobile-friendly UI on port 8088
  with live stats, historical charts, and a settings editor

## Requirements

- Raspberry Pi (any model) or Debian/Ubuntu Linux
- Python 3 (no pip packages needed — stdlib only)
- msmtp (for email alerts — optional)

## Installation

### 1. Clone the repo

```bash
cd ~
git clone https://github.com/josephdahan-lab/papamonitor.git
cd papamonitor
```

### 2. Configure email (optional)

Skip this step if you don't want email alerts — you can enable them later
from the web dashboard.

Create the msmtp config:

```bash
sudo nano /etc/msmtprc
```

Example for Gmail:

```
defaults
auth           on
tls            on
tls_trust_file /etc/ssl/certs/ca-certificates.crt
logfile        /var/log/msmtp.log

account        default
host           smtp.gmail.com
port           587
from           your-email@gmail.com
user           your-email@gmail.com
password       your-app-password
```

> **Note:** Gmail requires an [App Password](https://myaccount.google.com/apppasswords)
> if you have 2FA enabled. Regular passwords won't work.

Lock down permissions:

```bash
sudo chmod 600 /etc/msmtprc
```

Test it:

```bash
echo "Test from papamonitor" | msmtp your-email@example.com
```

### 3. Review thresholds (optional)

Edit `monitor.conf` before installing if you want to change the defaults:

```bash
nano monitor.conf
```

| Setting | Default | Description |
|---------|---------|-------------|
| `TEMP_WARN` | 70°C | Temperature warning threshold |
| `TEMP_CRIT` | 80°C | Temperature critical threshold |
| `MEM_WARN` | 90% | Memory usage alert |
| `DISK_WARN` | 85% | Disk usage warning |
| `DISK_CRIT` | 95% | Disk usage critical |
| `CPU_LOAD_WARN` | 0.9 | Load average per core |
| `WIFI_WARN` | -75 dBm | WiFi signal alert |
| `INTERVAL` | 60s | Polling interval |
| `EMAIL_TO` | admin@dahan.fr | Alert recipient (**change this**) |

All settings can also be changed live from the web dashboard's Settings card.

### 4. Run the installer

```bash
sudo bash setup.sh
```

This will:
- Install msmtp (if not already installed)
- Enable persistent journaling (needed for boot classification)
- Install and start three systemd services
- Set up daily log rotation

### 5. Verify

```bash
sudo systemctl status papamonitor
sudo systemctl status papamonitor-web
```

Open the dashboard: **http://\<pi-ip\>:8088**

## Services

| Service | Type | Description |
|---------|------|-------------|
| `papamonitor` | always-on | Runs `monitor.sh` in a loop — checks all metrics every `INTERVAL` seconds |
| `papamonitor-web` | always-on | Python web dashboard on port 8088 |
| `papamonitor-boot-check` | one-shot | Runs at boot — classifies the previous shutdown (clean reboot, power loss, crash) and sends an alert if unexpected |

## Usage

```bash
# Check service status
sudo systemctl status papamonitor

# View live monitor log
tail -f ~/papamonitor/monitor.log

# Restart after config changes (or just wait — monitor.conf is
# re-read every loop automatically)
sudo systemctl restart papamonitor

# Stop everything
sudo systemctl stop papamonitor papamonitor-web

# Disable on boot
sudo systemctl disable papamonitor papamonitor-web papamonitor-boot-check
```

## Uninstall

```bash
sudo systemctl stop papamonitor papamonitor-web papamonitor-boot-check
sudo systemctl disable papamonitor papamonitor-web papamonitor-boot-check
sudo rm /etc/systemd/system/papamonitor*.service
sudo rm /etc/logrotate.d/pi-monitor
sudo systemctl daemon-reload
```

## File structure

```
papamonitor/
├── setup.sh                      # Installer (run with sudo)
├── monitor.sh                    # Main monitor loop
├── monitor.conf                  # Thresholds and settings
├── web.py                        # Web dashboard server
├── boot_check.sh                 # Boot classifier
├── logrotate.conf                # Log rotation template
├── papamonitor.service           # systemd unit templates
├── papamonitor-web.service       #   (paths patched by setup.sh)
└── papamonitor-boot-check.service
```
