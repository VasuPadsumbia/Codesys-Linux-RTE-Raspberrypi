# User Guide
<!-- Author: Vasu Padsumbia -->

Day-to-day operation of the cclrte PLC platform.

---

## Accessing the WebUI

After first boot with WiFi configured, find the RPi5's wlan0 IP from your router's DHCP client list, or connect directly via eth0:

```
http://192.168.2.100:8080    (via Ethernet — always available)
http://<wlan0-ip>:8080       (via WiFi — check router for IP)
```

**Default credentials:**

| Username | Password |
|----------|----------|
| `admin`  | `admin`  |

**Change the password immediately after first login** via the System page → Change Password.

> The WebUI is served over HTTP. For production use, place an nginx reverse proxy with TLS in front of it.

---

## Dashboard

The dashboard (`/`) shows real-time status at a glance:

| Section | Description |
|---------|-------------|
| **Service Status** | Running/stopped state of codesyscontrol, ethercat, mosquitto, plc-webui, watchdog |
| **Network** | eth0 and wlan0 IP addresses, CODESYS IDE port, WebUI URL |
| **RT Latency** | Last cyclictest result — worst-case latency across CPU2/CPU3, pass/fail vs 100 µs threshold |
| **Hardware** | BCM2712 SoC temperature in °C, uptime, platform, RT mode |
| **PLC Load** | Live per-CPU load bars (updates every 2 s), memory usage, CODESYS process CPU %, temperature |

The status panel auto-refreshes every 5 seconds via `/api/status`. CPU load updates every 2 seconds via `/api/load`.

---

## Network Configuration

Navigate to **Network** (`/network`) to configure interfaces.

### eth0 — CODESYS Programming Port

| Field | Default | Notes |
|-------|---------|-------|
| IP Address | `192.168.2.100` | Must be reachable from CODESYS IDE PC |
| Prefix length | `24` | Subnet mask 255.255.255.0 |
| Gateway | `192.168.2.1` | — |

Changes write to `/etc/systemd/network/10-eth0.network` and restart `systemd-networkd`. A new IP takes effect within seconds.

> **Warning:** If you change eth0 to an IP not reachable from your CODESYS PC, you lose the programming connection until you reconnect via the correct IP or reconfigure via SSH on wlan0.

### wlan0 — Management Interface

| Field | Description |
|-------|-------------|
| SSID | WiFi network name |
| Password | WPA2-PSK passphrase |
| Country | ISO 3166-1 alpha-2 code for your region (e.g. `IN`, `US`, `DE`, `GB`) |

Changes update `/etc/wpa_supplicant/wpa_supplicant-wlan0.conf` and restart `wpa_supplicant@wlan0`. The new IP appears in the WebUI after reconnecting.

### SSH Key

Paste an SSH public key to add it to `/root/.ssh/authorized_keys` for passwordless login.

---

## Protocols Page

Navigate to **Protocols** (`/protocols`) to configure fieldbus settings.

### EtherCAT

- **Master device MAC**: Set the MAC address of the USB-to-Ethernet adapter used for EtherCAT.
  Writes to `/etc/ethercat.conf` (`MASTER0_DEVICE`) and restarts the `ethercat` service.

To find your EtherCAT NIC MAC:
```bash
ip link show eth1    # or the USB NIC device name
```

### MQTT (Mosquitto)

- Shows broker status and port (1883 / WebSocket 9001)
- Broker is always on `localhost` — CODESYS connects internally
- For external MQTT clients, connect to `<wlan0-ip>:1883`

### OPC-UA (open62541)

- Port 4840, integrated with CODESYS OPC-UA server SL
- Connect OPC-UA clients to `opc.tcp://192.168.2.100:4840`

### IO-Link

- SPI0 port for 4 IO-Link channels
- Device class and vendor info from connected IO-Link devices

### PROFINET

> **Note:** p-net implements PROFINET **device** (slave) mode only. The RPi5 appears as a PROFINET IO device that a PROFINET controller (e.g. Siemens S7 PLC) can read/write. PROFINET **controller** (master) mode requires the CODESYS PROFINET SL add-on.

---

## CODESYS Page

Navigate to **CODESYS** (`/codesys`) for runtime management.

### Service Status

Shows `codesyscontrol.service` state: active/inactive/failed.

### Install Runtime

If the packages were placed in `data/` before building, CODESYS is **auto-installed on first boot** — no action required. The page shows runtime status and log output.

To reinstall manually (e.g. after a package update):
```bash
rm /var/lib/cclrte/codesys-installed
systemctl start codesys-firstboot
journalctl -u codesys-firstboot -f
```

### Log Viewer

The last 30 lines of the CODESYS runtime log (`journalctl -u codesyscontrol`). Useful for diagnosing program download failures, watchdog trips, and OPC-UA errors.

---

## System Page

Navigate to **System** (`/system`) for system management.

| Action | Description |
|--------|-------------|
| **Reboot** | Graceful `systemctl reboot` — CODESYS performs orderly shutdown |
| **RT Verify** | Triggers a 3-phase cyclictest (~3 min); tests CPU2 at FIFO 90 and CPU3 at FIFO 80 independently |
| **Change Password** | Update WebUI admin password (PBKDF2-SHA256) |

### RT Verification Details

Clicking **Run cyclictest (~3 min)** starts `rt-verify.service` which runs three independent 60-second cyclictest phases:

| Phase | CPU | Priority | Tests |
|-------|-----|----------|-------|
| SMP baseline | all | FIFO 80 | OS scheduler noise |
| EtherCAT | CPU2 | FIFO 90 | EtherCAT master latency budget |
| CODESYS | CPU3 | FIFO 80 | PLC scan cycle latency budget |

CODESYS and EtherCAT do **not** need to be running — the test measures kernel RT performance directly. The result is stored at `/var/log/cclrte-rt-result.txt`.

---

## Programming with CODESYS IDE

### Connecting to the Runtime

Verify the runtime is listening before connecting:
```bash
ss -tlnp | grep 1217   # must show LISTEN — check codesys-firstboot if empty
```

1. Open CODESYS Development System (Windows or Linux)
2. **Online → Scan Network** — the `cclrte-plc` device appears automatically
3. Double-click the device → click **Login** (leave username/password blank — UserMgmt is disabled)
4. **Online → Download** your project

> **No login required by default:** `UserMgmtEnabled=0` is set in `CODESYSControl_User.cfg`. If asked for credentials, click OK with empty fields. If login fails silently, see the troubleshooting section in [INSTALLATION.md](INSTALLATION.md).

### Project Structure (Recommended)

```
MyMachineProject/
├── Device (CODESYS Control for Linux SL)
│   ├── EtherCAT_Master (IgH EtherCAT SL)
│   │   └── Axis1 (servo drive, e.g. BECKHOFF EL7201)
│   ├── MQTT_Client
│   ├── OPC_UA_Server
│   └── Modbus_Serial (CODESYS Modbus SL)
└── Application
    ├── GVL (Global Variable List)
    ├── MainTask (cyclic, 500 µs, priority 14)
    │   └── MAIN (POU)
    └── SlowTask (cyclic, 10 ms, priority 10)
        └── HMI_Update (POU)
```

### Task Configuration for Motion Control

In the CODESYS Task Configuration:
- **MainTask**: Cyclic, interval **500 µs** (or 250 µs with Xenomai), priority 14 (highest)
- **SlowTask**: Cyclic, 10 ms, priority 10

The kernel and `rt-setup.service` ensure the CODESYS process runs on CPU3 at SCHED_FIFO 80, so even 500 µs tasks complete deterministically.

### SoftMotion (Motion Control)

If using CODESYS SoftMotion:
1. Add SoftMotion library to project
2. Configure EtherCAT master with your drive's ESI file
3. Create Axis objects mapped to EtherCAT PDOs
4. Use `MC_MoveAbsolute`, `MC_MoveRelative`, etc. in MainTask

---

## Monitoring

### Real-Time Latency

```bash
# View last cyclictest result
cat /var/log/cclrte-rt-result.txt   # RT latency result

# Run a fresh latency test manually (~3 min, 3 phases)
/usr/sbin/run-cyclictest.sh

# Quick live check (10 seconds, 500µs interval, CPU3)
cyclictest --mlockall --affinity=3 --priority=80 --interval=500 --duration=10
```

### Service Logs

```bash
# CODESYS runtime log
journalctl -u codesyscontrol -f

# EtherCAT master log
journalctl -u ethercat -f

# RT setup log
journalctl -u rt-setup -f

# RT verification log
journalctl -u rt-verify -f

# WebUI log
journalctl -u plc-webui -f

# Network firstboot log
journalctl -u network-firstboot

# All services since boot
journalctl -b
```

### CPU and RT Stats

```bash
# CPU temperature (BCM2712 SoC)
cat /sys/class/thermal/thermal_zone0/temp | awk '{printf "%.1f°C\n", $1/1000}'

# CPU frequency (should be 2400000 with force_turbo=1)
cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_cur_freq

# CODESYS CPU affinity and priority
ps -eo pid,comm,cls,pri,psr | grep codesys
chrt -p $(pgrep -x codesyscontrol)
taskset -p $(pgrep -x codesyscontrol)

# EtherCAT master threads
ps -eo pid,comm,cls,pri,psr | grep ec_
```

---

## SSH Access

SSH is available on both eth0 and wlan0:

```bash
ssh root@192.168.2.100     # via Ethernet (always available)
ssh root@<wlan0-ip>        # via WiFi
# Default password: cclrte
```

The authorized key is set from `SSH_AUTHORIZED_KEY` in `config/site.conf` on first boot.

To add additional keys after deployment:
```bash
# Via WebUI: Network page → SSH Key section
# Via SSH:
echo "ssh-ed25519 AAAA... newuser@host" >> /root/.ssh/authorized_keys
```

---

## Changing WiFi Credentials After Deployment

### Via WebUI

Network page → wlan0 section → update SSID/Password → Apply.

### Via SSH

```bash
wpa_passphrase "NewSSID" "NewPassword" > /etc/wpa_supplicant/wpa_supplicant-wlan0.conf
echo "disable_scan_offload=1" >> /etc/wpa_supplicant/wpa_supplicant-wlan0.conf
systemctl restart wpa_supplicant@wlan0
```

### Via eth0 (if WiFi is unavailable)

Connect directly to eth0 (192.168.2.100) and use SSH over that interface, then update as above.

---

## Build Target Reference

| Feature | PREEMPT_RT | Xenomai Cobalt |
|---------|-----------|----------------|
| Worst-case latency | < 100 µs | 2–15 µs |
| Minimum cycle time | 500 µs | 250 µs |
| Kernel | `linux-raspberrypi` + RT patches | Dovetail-patched kernel + Cobalt |
| Userspace changes | None | `xenomai-libcobalt` required |
| Build complexity | Standard | Requires Dovetail patches for BCM2712 |
| RPi5 stability | Well-tested | Requires community Dovetail patches |
| Recommended for | Standard motion control | High-speed / many-axis |

To upgrade from PREEMPT_RT to Xenomai:
1. Obtain Dovetail patches (see [INSTALLATION.md](INSTALLATION.md))
2. Run `./cclrte.sh build xenomai`
3. Flash: `./cclrte.sh load /dev/sdX xenomai`
4. All CODESYS programs and configs carry over (same `/var/opt/codesys` partition)

---

## Watchdog Behavior

The hardware watchdog (BCM2712) has a 15-second hardware timeout. The watchdog daemon kicks it every 2 seconds with a 10-second software timeout.

If the system locks up or `codesyscontrol` hangs the kernel:
- After 10 seconds without a watchdog kick, the daemon triggers a soft reboot
- If the system is completely unresponsive, BCM2712 performs a hard reset at 15 seconds
- The system reboots automatically
- `codesyscontrol.service` restarts and resumes the last downloaded PLC program

The systemd service uses `Restart=on-failure` so if `codesyscontrol` exits unexpectedly it is restarted automatically after 5 seconds.
