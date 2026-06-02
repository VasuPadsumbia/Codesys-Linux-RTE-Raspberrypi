#!/usr/bin/env python3
"""
CCLRTE PLC WebUI — Flask-based configuration interface
Author: Vasu Padsumbia
Runs on port 8080 via wlan0 (management interface).
Provides: Dashboard, Network config, Protocol config, CODESYS management, System info.
"""

import os
import re
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

CODESYS_CFG  = '/etc/codesyscontrol/CODESYSControl.cfg'
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

def codesys_status():
    """Return CODESYS status — checks both systemd AND process so IDE-started runtimes show correctly."""
    svc = service_status('codesyscontrol')
    if svc == 'active':
        return 'active'
    # Fallback: check if the process is running even if systemd tracking is off
    pid_out, rc = run('pgrep -x codesyscontrol 2>/dev/null || pgrep -x codesysruntime 2>/dev/null')
    if rc == 0 and pid_out.strip():
        return 'active'
    return svc or 'inactive'

def get_ip(iface):
    out, _ = run(f"ip -4 addr show {iface} | awk '/inet /{{print $2}}' | cut -d/ -f1")
    return out or '—'

def get_scheduler_interval():
    """Read SchedulerInterval (µs) from the live CODESYS config."""
    try:
        with open(CODESYS_CFG) as f:
            for line in f:
                line = line.strip()
                if line.startswith('SchedulerInterval='):
                    return int(line.split('=', 1)[1])
    except Exception:
        pass
    return None

def set_scheduler_interval(value_us):
    """Write SchedulerInterval to the live CODESYS config. Returns (ok, msg)."""
    try:
        with open(CODESYS_CFG) as f:
            content = f.read()
        new_content = re.sub(r'^SchedulerInterval=\d+', f'SchedulerInterval={value_us}',
                             content, flags=re.MULTILINE)
        if new_content == content:
            return False, 'SchedulerInterval key not found in config'
        with open(CODESYS_CFG, 'w') as f:
            f.write(new_content)
        return True, f'SchedulerInterval set to {value_us} µs — restart CODESYS to apply'
    except Exception as e:
        return False, str(e)

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

# ── NTP mode persistence ──────────────────────────────────────────────────────
NTP_MODE_FILE = '/var/lib/cclrte/ntp-mode.json'

def _ntp_mode_labels():
    return {
        'a': 'Internet NTP (~5–20 ms)',
        'b': 'Engineering PC NTP (<1 ms)',
        'c': 'PTP IEEE 1588 (<1 µs)',
    }

def read_ntp_mode():
    try:
        with open(NTP_MODE_FILE) as f:
            return json.load(f)
    except Exception:
        return {'mode': 'a', 'pc_ip': ''}

def write_ntp_mode(mode, pc_ip='', timezone='UTC'):
    os.makedirs(os.path.dirname(NTP_MODE_FILE), exist_ok=True)
    with open(NTP_MODE_FILE, 'w') as f:
        json.dump({'mode': mode, 'pc_ip': pc_ip, 'timezone': timezone}, f)

def http_time_offset_s():
    """Return offset (local - real) in seconds by checking HTTP Date header.
    Returns None if no internet or request fails."""
    import urllib.request, email.utils
    try:
        with urllib.request.urlopen('http://google.com', timeout=4) as r:
            date_str = r.headers.get('Date', '')
            if not date_str:
                return None
            ref = email.utils.parsedate_to_datetime(date_str)
            local_utc = datetime.utcnow().replace(tzinfo=ref.tzinfo)
            return (local_utc - ref).total_seconds()
    except Exception:
        return None

def clock_info():
    """Return Pi clock: ISO timestamp, NTP sync state."""
    now = datetime.now()
    svc_out, svc_rc = run('systemctl is-active chronyd 2>/dev/null')
    ntp_running = svc_rc == 0 and svc_out.strip() == 'active'
    offset_ms = None
    ntp_synced = False
    if ntp_running:
        ctl_out, ctl_rc = run('chronyc tracking 2>/dev/null')
        if ctl_rc == 0 and ctl_out:
            # 00000000 = no source at all; 7F7F0101 = local clock fallback — both mean not synced
            no_source   = '00000000 ()' in ctl_out
            local_clock = '7F7F0101' in ctl_out
            has_ref     = 'Reference ID' in ctl_out
            ntp_synced  = has_ref and not no_source and not local_clock
            m = re.search(r'System time\s*:\s*([\d.]+)\s*seconds', ctl_out)
            if m and ntp_synced:
                offset_ms = round(float(m.group(1)) * 1000, 2)
        else:
            # chronyc unavailable — fall back to HTTP Date header
            off = http_time_offset_s()
            if off is not None:
                ntp_synced = abs(off) < 5.0
                offset_ms  = round(off * 1000, 1)
    ntp_cfg = read_ntp_mode()
    return {
        'iso':               now.strftime('%Y-%m-%dT%H:%M:%S'),
        'display':           now.strftime('%Y-%m-%d %H:%M:%S'),
        'ntp_synced':        ntp_synced,
        'offset_ms':         offset_ms,
        'sync_method_label': _ntp_mode_labels().get(ntp_cfg['mode'], 'Internet NTP'),
    }

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

# State for live cycle time measurement (delta between successive API calls)
_schedstat_last = {'timeslices': None, 'mono': None}

def get_live_cycle_us():
    """
    Measure actual CODESYS scan cycle time using /proc/<pid>/schedstat field 3
    (timeslices). Returns µs per cycle averaged since last call, or None.
    """
    global _schedstat_last
    try:
        out, rc = run("pgrep -x codesyscontrol")
        if rc != 0 or not out:
            _schedstat_last = {'timeslices': None, 'mono': None}
            return None
        pid = out.split()[0]
        with open(f'/proc/{pid}/schedstat') as f:
            parts = f.read().split()
        timeslices = int(parts[2])
        now = time.monotonic()

        prev_ts = _schedstat_last['timeslices']
        prev_t  = _schedstat_last['mono']
        _schedstat_last = {'timeslices': timeslices, 'mono': now}

        if prev_ts is None or prev_t is None:
            return None
        delta_ts = timeslices - prev_ts
        delta_t  = now - prev_t
        if delta_ts <= 0 or delta_t <= 0:
            return None
        return round((delta_t / delta_ts) * 1e6)
    except Exception:
        return None

# ── Routes ────────────────────────────────────────────────────────────────────

@app.route('/')
@login_required
def index():
    status = {
        'codesys':   codesys_status(),
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
    if 'xenomai' in kernel.lower():
        rt_mode = 'Xenomai Cobalt (experimental)'
    else:
        rt_mode = 'PREEMPT_RT'
    clk      = clock_info()
    return render_template('index.html',
        status=status, rt=rt,
        eth0_ip=eth0_ip, wlan_ip=wlan_ip,
        temp=temp, uptime=up,
        platform=hw_platform(), rt_mode=rt_mode,
        clock=clk)

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
        elif action == 'set_cycle_time':
            try:
                value_us = int(request.form.get('cycle_time_us', 0))
                if value_us not in (250, 500, 1000, 2000, 4000):
                    msg = ('error', 'Invalid cycle time — choose 250, 500, 1000, 2000 or 4000 µs')
                else:
                    ok, text = set_scheduler_interval(value_us)
                    msg = ('success' if ok else 'error', text)
            except ValueError:
                msg = ('error', 'Invalid cycle time value')

    cs_status          = codesys_status()
    cs_log, _          = run('journalctl -u codesyscontrol -n 30 --no-pager 2>/dev/null || echo "No logs"')
    rt_result          = read_rt_result()
    installed          = (os.path.exists('/opt/codesys/bin/codesyscontrol') or
                          os.path.exists('/var/lib/cclrte/codesys-installed'))
    scheduler_interval = get_scheduler_interval()
    eth0_ip            = get_ip('eth0')

    return render_template('codesys.html',
        msg=msg, cs_status=cs_status, cs_log=cs_log,
        rt_result=rt_result, installed=installed, eth0_ip=eth0_ip,
        scheduler_interval=scheduler_interval)

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
        'codesys':   codesys_status(),
        'ethercat':  service_status('ethercat'),
        'mosquitto': service_status('mosquitto'),
        'eth0_ip':   get_ip('eth0'),
        'wlan_ip':   get_ip('wlan0'),
        'temp_c':    cpu_temp(),
        'uptime':    uptime(),
        'rt':        read_rt_result(),
        'clock':     clock_info(),
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

@app.route('/timesync', methods=['GET', 'POST'])
@login_required
def timesync():
    ntp_cfg = read_ntp_mode()
    if request.method == 'POST':
        mode     = request.form.get('mode', 'a')
        pc_ip    = request.form.get('pc_ip', '').strip()
        timezone = request.form.get('timezone', 'UTC').strip()
        write_ntp_mode(mode, pc_ip, timezone)
        run(f'timedatectl set-timezone {timezone} 2>/dev/null')
        return redirect(url_for('index'))
    try:
        cur_tz = open('/etc/localtime').read(0) or ''  # just trigger OSError if missing
        import subprocess as _sp
        cur_tz = _sp.check_output(['readlink', '-f', '/etc/localtime'],
                                   text=True).strip().split('zoneinfo/')[-1]
    except Exception:
        cur_tz = ntp_cfg.get('timezone', 'UTC')
    return render_template('timesync.html',
        current_mode=ntp_cfg['mode'],
        saved_pc_ip=ntp_cfg.get('pc_ip', ''),
        current_tz=cur_tz)

@app.route('/api/clock')
@login_required
def api_clock():
    return jsonify(clock_info())

@app.route('/api/clock/sync', methods=['POST'])
@login_required
def api_clock_sync():
    ntp_cfg = read_ntp_mode()
    mode    = ntp_cfg['mode']
    pc_ip   = ntp_cfg.get('pc_ip', '')

    def _ensure_chronyd():
        svc_out, svc_rc = run('systemctl is-active chronyd 2>/dev/null')
        if svc_rc != 0 or svc_out.strip() != 'active':
            run('systemctl start chronyd')
            time.sleep(2)

    def _burst_and_step():
        run('chronyc burst 4/4 2>/dev/null')
        time.sleep(8)
        run('chronyc makestep 2>/dev/null')

    def _year_ok():
        """True if the system clock year is plausible (>= 2025)."""
        return datetime.now().year >= 2025

    if mode == 'b' and pc_ip:
        conf = '/etc/chrony/conf.d/20-local-pc.conf'
        try:
            with open(conf, 'w') as f:
                f.write('# Engineering PC — local NTP master over eth0\n')
                f.write(f'server {pc_ip} iburst prefer minpoll 4 maxpoll 6\n')
        except OSError as e:
            return jsonify({'ntp_synced': False, 'message': f'Failed — could not write chrony config: {e}'})
        run('systemctl restart chronyd')
        time.sleep(3)
        _burst_and_step()
        info = clock_info()
        if info['ntp_synced'] and _year_ok():
            info['message'] = f'Synced to PC {pc_ip} — offset {info["offset_ms"]} ms' if info['offset_ms'] is not None else f'Synced to PC {pc_ip}'
        else:
            info['message'] = f'Failed — could not reach PC {pc_ip} on eth0. Check PC IP and UDP port 123 firewall rule.'
            info['ntp_synced'] = False
        return jsonify(info)

    if mode == 'c':
        info = clock_info()
        info['message'] = 'PTP mode — sync is handled by ptp4l. Ensure grandmaster is active on your network.'
        return jsonify(info)

    # Mode A — internet NTP
    _ensure_chronyd()
    # Check internet reachability before attempting
    off_before = http_time_offset_s()
    if off_before is None:
        info = clock_info()
        info['ntp_synced'] = False
        info['message'] = 'Failed — no internet route. Check WiFi is connected and ip route shows default via wlan0.'
        return jsonify(info)

    _burst_and_step()
    info = clock_info()
    if info['ntp_synced'] and _year_ok():
        info['message'] = 'Clock synced' + (f' — offset {info["offset_ms"]} ms' if info['offset_ms'] is not None else '')
    else:
        off = http_time_offset_s()
        if off is not None:
            info['ntp_synced'] = False
            info['message'] = f'Sync in progress — offset still {round(abs(off*1000))} ms. chrony is stepping the clock, check again in 30 s.'
        else:
            info['ntp_synced'] = False
            info['message'] = 'Failed — internet was reachable but sync did not complete. Check chrony logs: journalctl -u chronyd'
    return jsonify(info)

@app.route('/api/codesys/log')
@login_required
def api_codesys_log():
    log_out, _ = run('journalctl -u codesyscontrol -n 50 --no-pager 2>/dev/null')
    return jsonify({'log': log_out})

@app.route('/api/codesys/cycle')
@login_required
def api_codesys_cycle():
    cycle_us = get_live_cycle_us()
    hz = round(1_000_000 / cycle_us) if cycle_us and cycle_us > 0 else None
    return jsonify({'cycle_us': cycle_us, 'hz': hz})

if __name__ == '__main__':
    app.run(host='0.0.0.0', port=8080, debug=False)
