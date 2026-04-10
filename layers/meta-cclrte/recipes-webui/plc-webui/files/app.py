#!/usr/bin/env python3
"""
CCLRTE PLC WebUI — Flask-based configuration interface
Author: Vasu Padsumbia
Runs on port 8080 via wlan0 (management interface).
Provides: Dashboard, Network config, Protocol config, CODESYS management, System info.
"""

import os
import json
import time
import subprocess
import configparser
from datetime import datetime
from flask import (
    Flask, render_template, request, jsonify,
    redirect, url_for, flash, session
)
from auth import login_required, check_credentials, set_password

app = Flask(__name__, template_folder='templates', static_folder='static')
app.secret_key = os.environ.get('WEBUI_SECRET', 'cclrte-change-in-production')

CODESYS_CFG  = '/etc/CODESYSControl.cfg'
ETHERCAT_CFG = '/etc/ethercat.conf'
NETWORK_DIR  = '/etc/systemd/network'
WPA_CONF     = '/etc/wpa_supplicant/wpa_supplicant-wlan0.conf'
RT_RESULT    = '/var/log/cclrte-rt-result.txt'

# ── Helpers ────────────────────────────────────────────────────────────────────

def run(cmd, check=False, timeout=10):
    try:
        r = subprocess.run(cmd, shell=True, capture_output=True, text=True, timeout=timeout)
        return r.stdout.strip(), r.returncode
    except Exception as e:
        return str(e), 1

def service_status(name):
    out, rc = run(f'systemctl is-active {name}')
    return out.strip()

def get_ip(iface):
    out, _ = run(f"ip -4 addr show {iface} | awk '/inet /{{print $2}}' | cut -d/ -f1")
    return out or '—'

def read_rt_result():
    try:
        with open(RT_RESULT) as f:
            return json.load(f)
    except Exception:
        return None

def hw_platform():
    """Read hardware platform string from device tree."""
    try:
        with open('/proc/device-tree/model', 'r') as f:
            return f.read().rstrip('\x00').strip()
    except Exception:
        pass
    try:
        with open('/proc/cpuinfo') as f:
            for line in f:
                if line.startswith('Model'):
                    return line.split(':', 1)[1].strip()
    except Exception:
        pass
    return 'Unknown'

def cpu_temp():
    try:
        with open('/sys/class/thermal/thermal_zone0/temp') as f:
            return round(int(f.read().strip()) / 1000, 1)
    except Exception:
        return '—'

def uptime():
    out, _ = run("awk '{printf \"%d days %02d:%02d\", $1/86400, ($1%86400)/3600, ($1%3600)/60}' /proc/uptime")
    return out

def cpu_loads():
    """Return per-CPU usage % by sampling /proc/stat over 200 ms."""
    def read_stat():
        cpus = {}
        with open('/proc/stat') as f:
            for line in f:
                if not line.startswith('cpu'):
                    break
                parts = line.split()
                name = parts[0]
                vals = list(map(int, parts[1:]))
                idle = vals[3] + vals[4]          # idle + iowait
                total = sum(vals)
                cpus[name] = (idle, total)
        return cpus
    try:
        s1 = read_stat()
        time.sleep(0.2)
        s2 = read_stat()
        result = {}
        for k in s1:
            di = s2[k][0] - s1[k][0]
            dt = s2[k][1] - s1[k][1]
            result[k] = round(100 * (1 - di / dt), 1) if dt else 0.0
        return result
    except Exception:
        return {}

def mem_info():
    """Return memory usage as dict with total_mb, used_mb, free_mb, percent."""
    try:
        info = {}
        with open('/proc/meminfo') as f:
            for line in f:
                k, v = line.split(':', 1)
                info[k.strip()] = int(v.split()[0])
        total = info.get('MemTotal', 0)
        available = info.get('MemAvailable', 0)
        used = total - available
        return {
            'total_mb': total // 1024,
            'used_mb':  used // 1024,
            'free_mb':  available // 1024,
            'percent':  round(100 * used / total, 1) if total else 0,
        }
    except Exception:
        return {}

def net_stats(iface):
    """Return rx_bytes and tx_bytes for an interface."""
    try:
        base = f'/sys/class/net/{iface}/statistics'
        rx = int(open(f'{base}/rx_bytes').read())
        tx = int(open(f'{base}/tx_bytes').read())
        return {'rx_bytes': rx, 'tx_bytes': tx}
    except Exception:
        return {'rx_bytes': 0, 'tx_bytes': 0}

def codesys_cpu():
    """Return CODESYS process CPU % from /proc/<pid>/stat."""
    try:
        out, rc = run("pgrep -x codesyscontrol || pgrep -x codesysruntime")
        if rc != 0 or not out:
            return None
        pid = out.split()[0]
        stat_out, _ = run(f"ps -p {pid} -o %cpu --no-headers")
        return float(stat_out.strip()) if stat_out.strip() else None
    except Exception:
        return None

# ── Routes ────────────────────────────────────────────────────────────────────

@app.route('/')
@login_required
def index():
    status = {
        'codesys':   service_status('codesyscontrol'),
        'ethercat':  service_status('ethercat'),
        'webui':     'active',
        'mosquitto': service_status('mosquitto'),
        'watchdog':  service_status('watchdog') or service_status('watchdog.service'),
    }
    rt = read_rt_result()
    eth0_ip  = get_ip('eth0')
    wlan_ip  = get_ip('wlan0')
    temp     = cpu_temp()
    up       = uptime()
    kernel, _ = run('uname -r')
    rt_mode  = 'XENOMAI' if 'xenomai' in kernel.lower() else 'PREEMPT_RT'
    return render_template('index.html',
        status=status, rt=rt,
        eth0_ip=eth0_ip, wlan_ip=wlan_ip,
        temp=temp, uptime=up,
        platform=hw_platform(), rt_mode=rt_mode)

@app.route('/network', methods=['GET', 'POST'])
@login_required
def network():
    msg = None
    if request.method == 'POST':
        action = request.form.get('action')
        if action == 'eth0':
            ip     = request.form.get('eth0_ip', '').strip()
            prefix = request.form.get('eth0_prefix', '24').strip()
            gw     = request.form.get('eth0_gw', '').strip()
            content = f"[Match]\nName=eth0\n\n[Network]\nAddress={ip}/{prefix}\nGateway={gw}\nDescription=CODESYS Programming Port\n\n[Link]\nWakeOnLan=off\n"
            try:
                with open(f'{NETWORK_DIR}/10-eth0.network', 'w') as f:
                    f.write(content)
                run('systemctl restart systemd-networkd')
                msg = ('success', f'eth0 configured: {ip}/{prefix}')
            except Exception as e:
                msg = ('error', str(e))
        elif action == 'wifi':
            ssid     = request.form.get('ssid', '').strip()
            password = request.form.get('password', '').strip()
            country  = request.form.get('country', 'IN').strip()
            if ssid and password:
                wpa_out, rc = run(f'wpa_passphrase "{ssid}" "{password}"')
                if rc == 0:
                    content = f"ctrl_interface=DIR=/var/run/wpa_supplicant\nupdate_config=1\ncountry={country}\ndisable_scan_offload=1\n\n{wpa_out}\n"
                    try:
                        with open(WPA_CONF, 'w') as f:
                            f.write(content)
                        os.chmod(WPA_CONF, 0o600)
                        run('systemctl restart wpa_supplicant@wlan0.service')
                        msg = ('success', f'WiFi configured for: {ssid}')
                    except Exception as e:
                        msg = ('error', str(e))
                else:
                    msg = ('error', 'wpa_passphrase failed')
            else:
                msg = ('error', 'SSID and password required')
        elif action == 'ssh_key':
            key = request.form.get('ssh_key', '').strip()
            if key.startswith('ssh-'):
                try:
                    os.makedirs('/root/.ssh', exist_ok=True)
                    with open('/root/.ssh/authorized_keys', 'a') as f:
                        f.write(key + '\n')
                    os.chmod('/root/.ssh/authorized_keys', 0o600)
                    msg = ('success', 'SSH key added')
                except Exception as e:
                    msg = ('error', str(e))
            else:
                msg = ('error', 'Invalid SSH public key format')

    eth0_ip = get_ip('eth0')
    wlan_ip = get_ip('wlan0')
    return render_template('network.html', msg=msg, eth0_ip=eth0_ip, wlan_ip=wlan_ip)

@app.route('/protocols', methods=['GET', 'POST'])
@login_required
def protocols():
    msg = None
    if request.method == 'POST':
        action = request.form.get('action')
        if action == 'ethercat':
            mac = request.form.get('master_device', '').strip()
            content = f"MASTER0_DEVICE=\"{mac}\"\nDEVICE_MODULES=\"generic\"\n"
            try:
                with open(ETHERCAT_CFG, 'w') as f:
                    f.write(content)
                run('systemctl restart ethercat')
                msg = ('success', 'EtherCAT configuration saved and service restarted')
            except Exception as e:
                msg = ('error', str(e))
        elif action == 'service_toggle':
            svc    = request.form.get('service', '')
            action = request.form.get('toggle', 'start')
            allowed = ['ethercat', 'mosquitto', 'codesyscontrol']
            if svc in allowed and action in ['start', 'stop', 'restart']:
                _, rc = run(f'systemctl {action} {svc}')
                msg = ('success' if rc == 0 else 'error',
                       f'{svc} {action}{"ed" if action != "restart" else "ed"}')

    statuses = {
        'ethercat':  service_status('ethercat'),
        'opcua':     'embedded in CODESYS',
        'mqtt':      service_status('mosquitto'),
        'profinet':  'p-net device stack',
        'iolink':    'configured via SPI',
        'modbus':    'via CODESYS SysCom',
    }
    ethercat_mac = ''
    try:
        with open(ETHERCAT_CFG) as f:
            for line in f:
                if line.startswith('MASTER0_DEVICE'):
                    ethercat_mac = line.split('=')[1].strip().strip('"')
    except Exception:
        pass

    return render_template('protocols.html', msg=msg, statuses=statuses, ethercat_mac=ethercat_mac)

@app.route('/codesys', methods=['GET', 'POST'])
@login_required
def codesys():
    msg = None
    if request.method == 'POST':
        action = request.form.get('action')
        if action in ['start', 'stop', 'restart']:
            _, rc = run(f'systemctl {action} codesyscontrol')
            msg = ('success' if rc == 0 else 'error', f'CODESYS {action}')
        elif action == 'install_check':
            exists = os.path.exists('/opt/codesys/bin/codesyscontrol.bin')
            msg = ('success' if exists else 'warning',
                   'Runtime installed' if exists else 'Runtime not installed — run install-codesys-runtime.sh')

    cs_status  = service_status('codesyscontrol')
    cs_log, _  = run('journalctl -u codesyscontrol -n 30 --no-pager 2>/dev/null || echo "No logs"')
    rt_result  = read_rt_result()
    installed  = os.path.exists('/opt/codesys/bin/codesyscontrol.bin')
    eth0_ip    = get_ip('eth0')

    return render_template('codesys.html',
        msg=msg, cs_status=cs_status, cs_log=cs_log,
        rt_result=rt_result, installed=installed, eth0_ip=eth0_ip)

@app.route('/system', methods=['GET', 'POST'])
@login_required
def system():
    msg = None
    if request.method == 'POST':
        action = request.form.get('action')
        if action == 'reboot':
            run('systemctl reboot')
        elif action == 'change_password':
            old = request.form.get('old_password', '')
            new = request.form.get('new_password', '')
            if check_credentials('admin', old):
                set_password('admin', new)
                msg = ('success', 'Password changed')
            else:
                msg = ('error', 'Current password incorrect')
        elif action == 'rt_verify':
            # Delete old result then stop any running instance before starting fresh
            run(f'rm -f {RT_RESULT}')
            run('systemctl stop rt-verify 2>/dev/null || true', timeout=15)
            run('systemctl reset-failed rt-verify 2>/dev/null || true')
            # Start in background — oneshot takes ~3 min, don't wait
            run('systemctl start rt-verify &', timeout=5)
            msg = ('success', 'RT verification started — 3 phases (~3 min). Refresh this page when done.')

    mem_out, _ = run("free -m | awk 'NR==2{printf \"%s/%s MB\", $3, $2}'")
    disk_out, _ = run("df -h / | awk 'NR==2{printf \"%s/%s (%s)\", $3, $2, $5}'")
    kernel_out, _ = run('uname -r')
    rt_result = read_rt_result()

    return render_template('system.html',
        msg=msg, temp=cpu_temp(), uptime=uptime(),
        memory=mem_out, disk=disk_out, kernel=kernel_out,
        rt_result=rt_result, platform=hw_platform())

# ── Auth routes ────────────────────────────────────────────────────────────────

@app.route('/login', methods=['GET', 'POST'])
def login():
    if request.method == 'POST':
        username = request.form.get('username', '')
        password = request.form.get('password', '')
        if check_credentials(username, password):
            session['user'] = username
            return redirect(url_for('index'))
        flash('Invalid credentials', 'error')
    return render_template('login.html')

@app.route('/logout')
def logout():
    session.pop('user', None)
    return redirect(url_for('login'))

# ── API endpoints (for JS polling) ────────────────────────────────────────────

@app.route('/api/status')
@login_required
def api_status():
    return jsonify({
        'codesys':  service_status('codesyscontrol'),
        'ethercat': service_status('ethercat'),
        'mosquitto': service_status('mosquitto'),
        'eth0_ip':  get_ip('eth0'),
        'wlan_ip':  get_ip('wlan0'),
        'temp_c':   cpu_temp(),
        'uptime':   uptime(),
        'rt':       read_rt_result(),
        'timestamp': datetime.now().isoformat(),
    })

@app.route('/api/load')
@login_required
def api_load():
    loads = cpu_loads()
    mem   = mem_info()
    return jsonify({
        'cpu': {
            'total':  loads.get('cpu', 0),
            'core0':  loads.get('cpu0', 0),
            'core1':  loads.get('cpu1', 0),
            'core2':  loads.get('cpu2', 0),   # EtherCAT
            'core3':  loads.get('cpu3', 0),   # CODESYS
        },
        'memory': mem,
        'codesys_cpu_pct': codesys_cpu(),
        'net': {
            'eth0':  net_stats('eth0'),
            'wlan0': net_stats('wlan0'),
        },
        'temp_c':  cpu_temp(),
        'timestamp': datetime.now().isoformat(),
    })

@app.route('/api/codesys/log')
@login_required
def api_codesys_log():
    log_out, _ = run('journalctl -u codesyscontrol -n 50 --no-pager 2>/dev/null')
    return jsonify({'log': log_out})

if __name__ == '__main__':
    app.run(host='0.0.0.0', port=8080, debug=False)
