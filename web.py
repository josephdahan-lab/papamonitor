#!/usr/bin/env python3
import http.server
import json
import subprocess
import os
import re
from datetime import datetime, timedelta

PORT = 8088
MONITOR_LOG = os.path.expanduser("~/monitor/monitor.log")
BOOTS_LOG = os.path.expanduser("~/monitor/boots.log")

def run_cmd(cmd):
    try:
        return subprocess.check_output(cmd, shell=True, stderr=subprocess.DEVNULL, timeout=10).decode().strip()
    except Exception:
        return ""

def get_live_stats():
    temp = run_cmd("vcgencmd measure_temp | grep -oP '[0-9.]+'")
    cpu_pct = run_cmd("top -bn2 -d0.3 | grep '%Cpu' | tail -1 | awk '{print 100 - $8}'")
    load = run_cmd("cat /proc/loadavg | awk '{print $1, $2, $3}'")
    mem = run_cmd("free -m | awk '/Mem/{printf \"%d %d\", $3, $2}'").split()
    swap = run_cmd("free -m | awk '/Swap/{printf \"%d %d\", $3, $2}'").split()
    uptime_str = run_cmd("uptime -p")
    uptime_since = run_cmd("uptime -s")
    wifi = run_cmd("iwconfig wlan0 2>/dev/null | awk -F= '/Signal level/{print $3+0}'")
    wifi_essid = run_cmd("iwconfig wlan0 2>/dev/null | grep -oP 'ESSID:\"\\K[^\"]+' ")
    hostname = run_cmd("hostname")
    ip = run_cmd("hostname -I | awk '{print $1}'")
    kernel = run_cmd("uname -r")
    cpu_model = run_cmd("grep -m1 'Model' /proc/cpuinfo | cut -d: -f2").strip() or run_cmd("grep -m1 'model name' /proc/cpuinfo | cut -d: -f2").strip()
    num_cores = run_cmd("nproc")
    throttled = run_cmd("vcgencmd get_throttled | cut -d= -f2")

    disks = []
    df_out = run_cmd("df -h --output=source,fstype,size,used,avail,pcent,target | tail -n +2")
    for line in df_out.splitlines():
        parts = line.split()
        if len(parts) >= 7 and not parts[0].startswith("tmpfs") and not parts[0].startswith("devtmpfs"):
            disks.append({
                "device": parts[0],
                "fstype": parts[1],
                "size": parts[2],
                "used": parts[3],
                "avail": parts[4],
                "pct": int(parts[5].replace("%", "")),
                "mount": parts[6],
            })

    top_procs = []
    ps_out = run_cmd("ps aux --sort=-%cpu | head -8")
    for line in ps_out.splitlines()[1:]:
        parts = line.split(None, 10)
        if len(parts) >= 11:
            top_procs.append({
                "user": parts[0], "cpu": parts[2], "mem": parts[3],
                "pid": parts[1], "cmd": parts[10][:80],
            })

    return {
        "hostname": hostname, "ip": ip, "kernel": kernel,
        "cpu_model": cpu_model, "num_cores": num_cores,
        "temp": temp, "cpu_pct": cpu_pct, "load": load,
        "mem_used": mem[0] if mem else "0", "mem_total": mem[1] if len(mem) > 1 else "0",
        "swap_used": swap[0] if swap else "0", "swap_total": swap[1] if len(swap) > 1 else "0",
        "uptime": uptime_str, "uptime_since": uptime_since,
        "wifi_signal": wifi, "wifi_essid": wifi_essid,
        "throttled": throttled,
        "disks": disks, "top_procs": top_procs,
    }

def get_log_history(lines=120):
    entries = []
    try:
        with open(MONITOR_LOG) as f:
            all_lines = f.readlines()
        for line in all_lines[-lines:]:
            line = line.strip()
            if "| temp=" not in line:
                continue
            m = re.match(
                r'([\d-]+ [\d:]+) \| temp=([\d.]+).*cpu=([\d.]+)%.*load=([\d.]+).*mem=(\d+)/(\d+).*disk=(\d+)%.*wifi=(-?\d+)',
                line
            )
            if m:
                entries.append({
                    "time": m.group(1), "temp": float(m.group(2)),
                    "cpu": float(m.group(3)), "load": float(m.group(4)),
                    "mem_used": int(m.group(5)), "mem_total": int(m.group(6)),
                    "disk_pct": int(m.group(7)), "wifi": int(m.group(8)),
                })
    except FileNotFoundError:
        pass
    return entries

def get_old_log_history(lines=1500):
    """Parse old-format log lines from before the monitor upgrade."""
    entries = []
    try:
        with open(MONITOR_LOG) as f:
            all_lines = f.readlines()
        for line in all_lines[-lines:]:
            line = line.strip()
            if "temp=temp=" in line:
                m = re.match(
                    r'(\w+ \d+ \w+ [\d:]+ \w+ \d+) \| temp=temp=([\d.]+).*mem=(\d+)/(\d+)MB.*wifi=level=(-?\d+)',
                    line
                )
                if m:
                    entries.append({
                        "time": m.group(1), "temp": float(m.group(2)),
                        "cpu": 0, "load": 0,
                        "mem_used": int(m.group(3)), "mem_total": int(m.group(4)),
                        "disk_pct": 0, "wifi": int(m.group(5)),
                    })
    except FileNotFoundError:
        pass
    return entries

def get_boots():
    boots = []
    try:
        with open(BOOTS_LOG) as f:
            boots = [l.strip() for l in f.readlines() if l.strip()]
    except FileNotFoundError:
        pass
    jctl = run_cmd("journalctl --list-boots --no-pager 2>/dev/null")
    return {"log": boots, "journalctl": jctl}

def get_warnings(lines=200):
    warnings = []
    try:
        with open(MONITOR_LOG) as f:
            for line in f.readlines()[-lines:]:
                if "WARNING" in line or "ALERT" in line or "BOOT" in line:
                    warnings.append(line.strip())
    except FileNotFoundError:
        pass
    return warnings[-30:]


HTML = """<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>papaMonitor</title>
<style>
  :root {
    --bg: #0f1117; --card: #1a1d27; --border: #2a2d3a;
    --text: #e0e0e0; --dim: #888; --accent: #4fc3f7;
    --green: #66bb6a; --yellow: #fdd835; --orange: #ffa726; --red: #ef5350;
  }
  * { margin: 0; padding: 0; box-sizing: border-box; }
  body { font-family: 'SF Mono', 'Consolas', 'Fira Code', monospace; background: var(--bg); color: var(--text); font-size: 14px; }
  .header { background: var(--card); border-bottom: 1px solid var(--border); padding: 16px 24px; display: flex; justify-content: space-between; align-items: center; flex-wrap: wrap; gap: 8px; }
  .header h1 { font-size: 20px; font-weight: 400; }
  .header h1 b { font-weight: 700; }
  .header h1 span { color: var(--accent); }
  .meta { color: var(--dim); font-size: 12px; }
  .grid { display: grid; grid-template-columns: repeat(auto-fit, minmax(340px, 1fr)); gap: 16px; padding: 16px 24px; }
  .card { background: var(--card); border: 1px solid var(--border); border-radius: 8px; padding: 16px; }
  .card h2 { font-size: 13px; color: var(--dim); text-transform: uppercase; letter-spacing: 1px; margin-bottom: 12px; }
  .stat-row { display: flex; justify-content: space-between; padding: 6px 0; border-bottom: 1px solid var(--border); }
  .stat-row:last-child { border-bottom: none; }
  .stat-label { color: var(--dim); }
  .stat-value { font-weight: 600; }
  .bar-container { background: #222; border-radius: 4px; height: 20px; margin: 4px 0; overflow: hidden; }
  .bar { height: 100%; border-radius: 4px; transition: width 0.5s; display: flex; align-items: center; padding-left: 8px; font-size: 11px; font-weight: 600; min-width: 30px; }
  .bar.green { background: var(--green); }
  .bar.yellow { background: var(--yellow); color: #333; }
  .bar.orange { background: var(--orange); color: #333; }
  .bar.red { background: var(--red); }
  .disk-entry { margin-bottom: 12px; }
  .disk-header { display: flex; justify-content: space-between; font-size: 13px; margin-bottom: 2px; }
  table { width: 100%; border-collapse: collapse; font-size: 12px; }
  th { text-align: left; color: var(--dim); padding: 4px 8px; border-bottom: 1px solid var(--border); }
  td { padding: 4px 8px; border-bottom: 1px solid var(--border); }
  .warn-line { font-size: 12px; padding: 3px 0; border-bottom: 1px solid var(--border); word-break: break-all; }
  .warn-line:last-child { border-bottom: none; }
  .chart-area { width: 100%; height: 120px; position: relative; }
  canvas { width: 100% !important; height: 120px !important; }
  .full-width { grid-column: 1 / -1; }
  .refresh-note { color: var(--dim); font-size: 11px; }
  .badge { display: inline-block; padding: 2px 8px; border-radius: 4px; font-size: 11px; font-weight: 600; }
  .badge-ok { background: #1b3a1b; color: var(--green); }
  .badge-warn { background: #3a3a1b; color: var(--yellow); }
  .badge-crit { background: #3a1b1b; color: var(--red); }
  @media (max-width: 600px) { .grid { padding: 8px; gap: 8px; } .header { padding: 12px; } }
</style>
</head>
<body>
<div class="header">
  <h1><span>&#9679;</span> papa<b>Monitor</b></h1>
  <div class="meta">
    <span id="hostname"></span> &middot; <span id="ip"></span> &middot;
    <span class="refresh-note">auto-refresh 30s</span>
  </div>
</div>
<div class="grid">

  <div class="card">
    <h2>System</h2>
    <div class="stat-row"><span class="stat-label">Host</span><span class="stat-value" id="s-host"></span></div>
    <div class="stat-row"><span class="stat-label">IP</span><span class="stat-value" id="s-ip"></span></div>
    <div class="stat-row"><span class="stat-label">Kernel</span><span class="stat-value" id="s-kernel"></span></div>
    <div class="stat-row"><span class="stat-label">CPU</span><span class="stat-value" id="s-cpu-model"></span></div>
    <div class="stat-row"><span class="stat-label">Cores</span><span class="stat-value" id="s-cores"></span></div>
    <div class="stat-row"><span class="stat-label">Uptime</span><span class="stat-value" id="s-uptime"></span></div>
    <div class="stat-row"><span class="stat-label">Since</span><span class="stat-value" id="s-since"></span></div>
    <div class="stat-row"><span class="stat-label">Throttled</span><span class="stat-value" id="s-throttled"></span></div>
  </div>

  <div class="card">
    <h2>CPU &amp; Temperature</h2>
    <div class="stat-row"><span class="stat-label">Temperature</span><span class="stat-value" id="s-temp"></span></div>
    <div class="bar-container"><div class="bar" id="bar-temp"></div></div>
    <div class="stat-row"><span class="stat-label">CPU Usage</span><span class="stat-value" id="s-cpu"></span></div>
    <div class="bar-container"><div class="bar" id="bar-cpu"></div></div>
    <div class="stat-row"><span class="stat-label">Load Avg</span><span class="stat-value" id="s-load"></span></div>
  </div>

  <div class="card">
    <h2>Memory</h2>
    <div class="stat-row"><span class="stat-label">RAM</span><span class="stat-value" id="s-mem"></span></div>
    <div class="bar-container"><div class="bar" id="bar-mem"></div></div>
    <div class="stat-row"><span class="stat-label">Swap</span><span class="stat-value" id="s-swap"></span></div>
    <div class="bar-container"><div class="bar" id="bar-swap"></div></div>
  </div>

  <div class="card">
    <h2>Network</h2>
    <div class="stat-row"><span class="stat-label">WiFi ESSID</span><span class="stat-value" id="s-essid"></span></div>
    <div class="stat-row"><span class="stat-label">Signal</span><span class="stat-value" id="s-wifi"></span></div>
    <div class="bar-container"><div class="bar" id="bar-wifi"></div></div>
  </div>

  <div class="card full-width">
    <h2>Drives</h2>
    <div id="drives"></div>
  </div>

  <div class="card full-width">
    <h2>Top Processes</h2>
    <table>
      <thead><tr><th>PID</th><th>User</th><th>CPU%</th><th>MEM%</th><th>Command</th></tr></thead>
      <tbody id="procs"></tbody>
    </table>
  </div>

  <div class="card full-width">
    <h2>Temperature History</h2>
    <div class="chart-area"><canvas id="chart-temp"></canvas></div>
  </div>

  <div class="card full-width">
    <h2>CPU &amp; Memory History</h2>
    <div class="chart-area"><canvas id="chart-cpu-mem"></canvas></div>
  </div>

  <div class="card full-width">
    <h2>Boot History</h2>
    <div id="boots" style="font-size:12px;"></div>
  </div>

  <div class="card full-width">
    <h2>Recent Warnings &amp; Alerts</h2>
    <div id="warnings"></div>
  </div>

</div>

<script>
function barColor(pct) {
  if (pct < 60) return 'green';
  if (pct < 80) return 'yellow';
  if (pct < 90) return 'orange';
  return 'red';
}

function setBar(id, pct, label) {
  const el = document.getElementById(id);
  el.style.width = Math.max(pct, 3) + '%';
  el.className = 'bar ' + barColor(pct);
  el.textContent = label || (pct + '%');
}

function wifiPct(dbm) {
  // -30 = best, -90 = worst
  return Math.max(0, Math.min(100, (dbm + 90) / 60 * 100));
}

function tempPct(t) { return Math.max(0, Math.min(100, (t / 85) * 100)); }

function drawChart(canvasId, labels, datasets) {
  const canvas = document.getElementById(canvasId);
  const ctx = canvas.getContext('2d');
  const W = canvas.width = canvas.offsetWidth * 2;
  const H = canvas.height = 240;
  ctx.clearRect(0, 0, W, H);

  const pad = {top: 20, bottom: 25, left: 45, right: 15};
  const cw = W - pad.left - pad.right;
  const ch = H - pad.top - pad.bottom;

  let globalMin = Infinity, globalMax = -Infinity;
  for (const ds of datasets) {
    for (const v of ds.data) { globalMin = Math.min(globalMin, v); globalMax = Math.max(globalMax, v); }
  }
  const range = globalMax - globalMin || 1;
  globalMin -= range * 0.1; globalMax += range * 0.1;
  const yRange = globalMax - globalMin;

  ctx.strokeStyle = '#2a2d3a'; ctx.lineWidth = 1;
  ctx.font = '20px monospace'; ctx.fillStyle = '#666';
  for (let i = 0; i <= 4; i++) {
    const y = pad.top + (ch / 4) * i;
    ctx.beginPath(); ctx.moveTo(pad.left, y); ctx.lineTo(W - pad.right, y); ctx.stroke();
    const val = globalMax - (yRange / 4) * i;
    ctx.fillText(val.toFixed(0), 4, y + 5);
  }

  const step = labels.length > 1 ? cw / (labels.length - 1) : 0;
  // time labels
  ctx.fillStyle = '#555'; ctx.font = '18px monospace';
  const labelSkip = Math.ceil(labels.length / 8);
  for (let i = 0; i < labels.length; i += labelSkip) {
    const x = pad.left + i * step;
    const short = labels[i].split(' ').pop() || labels[i];
    ctx.fillText(short.substring(0, 5), x - 15, H - 4);
  }

  for (const ds of datasets) {
    ctx.beginPath(); ctx.strokeStyle = ds.color; ctx.lineWidth = 2.5;
    for (let i = 0; i < ds.data.length; i++) {
      const x = pad.left + i * step;
      const y = pad.top + ch - ((ds.data[i] - globalMin) / yRange) * ch;
      if (i === 0) ctx.moveTo(x, y); else ctx.lineTo(x, y);
    }
    ctx.stroke();
    // legend
    const li = datasets.indexOf(ds);
    ctx.fillStyle = ds.color; ctx.font = 'bold 20px monospace';
    ctx.fillText(ds.label, pad.left + li * 120, 14);
  }
}

async function refresh() {
  try {
    const res = await fetch('/api/stats');
    const d = await res.json();

    document.getElementById('hostname').textContent = d.live.hostname;
    document.getElementById('ip').textContent = d.live.ip;
    document.getElementById('s-host').textContent = d.live.hostname;
    document.getElementById('s-ip').textContent = d.live.ip;
    document.getElementById('s-kernel').textContent = d.live.kernel;
    document.getElementById('s-cpu-model').textContent = d.live.cpu_model;
    document.getElementById('s-cores').textContent = d.live.num_cores;
    document.getElementById('s-uptime').textContent = d.live.uptime;
    document.getElementById('s-since').textContent = d.live.uptime_since;

    const thr = d.live.throttled;
    const thrEl = document.getElementById('s-throttled');
    if (thr === '0x0') { thrEl.innerHTML = '<span class="badge badge-ok">None</span>'; }
    else { thrEl.innerHTML = '<span class="badge badge-crit">' + thr + '</span>'; }

    const temp = parseFloat(d.live.temp) || 0;
    document.getElementById('s-temp').textContent = temp + '°C';
    setBar('bar-temp', tempPct(temp), temp + '°C');

    const cpu = parseFloat(d.live.cpu_pct) || 0;
    document.getElementById('s-cpu').textContent = cpu.toFixed(1) + '%';
    setBar('bar-cpu', cpu, cpu.toFixed(1) + '%');
    document.getElementById('s-load').textContent = d.live.load;

    const mu = parseInt(d.live.mem_used), mt = parseInt(d.live.mem_total);
    const mp = mt > 0 ? Math.round(mu / mt * 100) : 0;
    document.getElementById('s-mem').textContent = mu + ' / ' + mt + ' MB (' + mp + '%)';
    setBar('bar-mem', mp, mp + '%');

    const su = parseInt(d.live.swap_used), st_ = parseInt(d.live.swap_total);
    const sp = st_ > 0 ? Math.round(su / st_ * 100) : 0;
    document.getElementById('s-swap').textContent = su + ' / ' + st_ + ' MB (' + sp + '%)';
    setBar('bar-swap', sp, sp + '%');

    const wifi = parseInt(d.live.wifi_signal) || -90;
    document.getElementById('s-essid').textContent = d.live.wifi_essid || '—';
    document.getElementById('s-wifi').textContent = wifi + ' dBm';
    setBar('bar-wifi', wifiPct(wifi), wifi + ' dBm');

    // drives
    let dhtml = '';
    for (const dk of d.live.disks) {
      const c = barColor(dk.pct);
      dhtml += '<div class="disk-entry">' +
        '<div class="disk-header"><span>' + dk.device + ' → ' + dk.mount + ' (' + dk.fstype + ')</span>' +
        '<span>' + dk.used + ' / ' + dk.size + ' (' + dk.pct + '%)</span></div>' +
        '<div class="bar-container"><div class="bar ' + c + '" style="width:' + Math.max(dk.pct,3) + '%">' + dk.pct + '%</div></div></div>';
    }
    document.getElementById('drives').innerHTML = dhtml;

    // procs
    let phtml = '';
    for (const p of d.live.top_procs) {
      phtml += '<tr><td>' + p.pid + '</td><td>' + p.user + '</td><td>' + p.cpu + '</td><td>' + p.mem + '</td><td>' + p.cmd + '</td></tr>';
    }
    document.getElementById('procs').innerHTML = phtml;

    // charts
    const hist = d.history.length > 0 ? d.history : d.old_history;
    if (hist.length > 2) {
      const labels = hist.map(h => h.time);
      drawChart('chart-temp', labels, [
        {label: 'Temp °C', color: '#ef5350', data: hist.map(h => h.temp)},
      ]);
      drawChart('chart-cpu-mem', labels, [
        {label: 'CPU %', color: '#4fc3f7', data: hist.map(h => h.cpu)},
        {label: 'MEM %', color: '#66bb6a', data: hist.map(h => h.mem_total > 0 ? (h.mem_used / h.mem_total * 100) : 0)},
      ]);
    }

    // boots
    let bhtml = '';
    if (d.boots.log.length > 0) {
      for (const b of d.boots.log) {
        const cls = b.includes('UNEXPECTED') || b.includes('CRASH') || b.includes('POWER') ? 'badge-crit' :
                    b.includes('USER_REBOOT') || b.includes('USER_SHUTDOWN') ? 'badge-ok' : 'badge-warn';
        bhtml += '<div class="warn-line"><span class="badge ' + cls + '">' +
          (b.match(/BOOT: (\w+)/)||[,''])[1] + '</span> ' + b + '</div>';
      }
    }
    if (d.boots.journalctl) { bhtml += '<pre style="color:#888;margin-top:8px;font-size:11px">' + d.boots.journalctl + '</pre>'; }
    document.getElementById('boots').innerHTML = bhtml || '<span style="color:#666">No boot records yet</span>';

    // warnings
    let whtml = '';
    for (const w of d.warnings) {
      whtml += '<div class="warn-line">' + w + '</div>';
    }
    document.getElementById('warnings').innerHTML = whtml || '<span style="color:#666">No recent warnings</span>';

  } catch(e) { console.error('refresh failed', e); }
}

refresh();
setInterval(refresh, 30000);
</script>
</body>
</html>"""


class Handler(http.server.BaseHTTPRequestHandler):
    def log_message(self, format, *args):
        pass

    def do_GET(self):
        if self.path == "/api/stats":
            data = {
                "live": get_live_stats(),
                "history": get_log_history(120),
                "old_history": get_old_log_history(1500),
                "boots": get_boots(),
                "warnings": get_warnings(),
            }
            self.send_response(200)
            self.send_header("Content-Type", "application/json")
            self.end_headers()
            self.wfile.write(json.dumps(data).encode())
        elif self.path == "/" or self.path == "/index.html":
            self.send_response(200)
            self.send_header("Content-Type", "text/html")
            self.end_headers()
            self.wfile.write(HTML.encode())
        else:
            self.send_response(404)
            self.end_headers()


if __name__ == "__main__":
    server = http.server.HTTPServer(("0.0.0.0", PORT), Handler)
    print(f"Monitor dashboard running on http://0.0.0.0:{PORT}")
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        server.shutdown()
