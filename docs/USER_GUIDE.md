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
| **Clock & Time Sync** | Live Pi clock, NTP sync badge, offset in ms, current sync method, Sync button |
| **CODESYS Runtime** | Runtime status, programming port, CPU affinity, live cycle time |

The status panel auto-refreshes every 5 seconds via `/api/status`. CPU load updates every 2 seconds via `/api/load`. The clock updates every second via `/api/clock`.

---

## Time Synchronisation

Accurate time is required so CODESYS log timestamps and OPC-UA event timestamps match the engineering PC and SCADA system.

### Configuring the sync method

Click **change** beside the Sync Method on the dashboard to open the time sync configuration page (`/timesync`).

**Step 1 — Select your timezone** from the dropdown at the top of the page. This sets the display timezone on the Pi (NTP always syncs to UTC internally). The timezone takes effect immediately when you save.

**Step 2 — Select a sync method:**

| Method | Accuracy | When to use |
|--------|----------|-------------|
| **A — Internet NTP** | ~5–20 ms | wlan0 is connected to a WiFi network with internet access |
| **B — Engineering PC (LAN)** | < 1 ms | Airgapped — no internet; PC and Pi on the same 192.168.2.x network |
| **C — PTP IEEE 1588** | < 1 µs | Microsecond alignment required; dedicated PTP grandmaster on network |

Click **Save & Return to Dashboard** — the method is saved and the timezone is applied immediately.

### Method B — Windows PC as NTP server

Run the following as Administrator on the engineering PC **before** clicking Apply:

```cmd
w32tm /config /manualpeerlist:"time.windows.com" /syncfromflags:manual /reliable:YES /update
net stop w32tm && net start w32tm
```

Then allow **UDP port 123 inbound** in Windows Defender Firewall, and enter the PC's 192.168.2.x IP address on the timesync page.

### Method C — PTP IEEE 1588

Install a PTP grandmaster on the 192.168.2.x network (Meinberg LANTIME hardware, or `ptp4l` on a Linux host in master mode). The Pi runs `ptp4l` in slave mode and `phc2sys` to sync the system clock from the PTP hardware clock.

### Sync Time Now button

Once a method is configured, click **Sync Time Now** on the dashboard to force an immediate synchronisation. The button reports the actual result — if sync fails (no internet route, PC unreachable, wrong timezone offset) it shows the error rather than a false success.

> **Note:** If the clock shows the wrong year after a fresh flash, the hardware RTC has drifted. Connect to WiFi and click **Sync Time Now** to correct it. Once chrony has synced successfully it writes the correct time to the RTC (`rtcsync`), so the correct time persists across reboots even without network.

---

## Network Configuration

Navigate to **Network** (`/network`) to configure interfaces.

### eth0 — CODESYS Programming Port

| Field | Default | Notes |
|-------|---------|-------|
| IP Address | `192.168.2.100` | Must be reachable from CODESYS IDE PC |
| Prefix length | `24` | Subnet mask 255.255.255.0 |

eth0 has **no default gateway** by design — internet traffic routes through wlan0 only. This prevents the CODESYS wired link from intercepting NTP, DNS, or MQTT traffic when the PC has no internet uplink.

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
- **MainTask**: Cyclic, interval **500 µs**, priority 14 (highest)
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

| Feature | PREEMPT_RT | Xenomai Cobalt (current) |
|---------|-----------|--------------------------|
| Worst-case latency | < 100 µs | Lower than PREEMPT_RT (Dovetail IRQ pipeline); full 2–15 µs requires libcobalt tasks — not yet implemented |
| Minimum cycle time | 500 µs | 500 µs (same — CODESYS still runs as Linux thread) |
| Kernel | `linux-raspberrypi` + RT patches | Dovetail-patched kernel + Cobalt co-kernel |
| Userspace | Standard | `xenomai-libcobalt` **not yet included** (no scarthgap meta-xenomai layer) |
| CODESYS scheduling | Linux PREEMPT_RT SCHED_FIFO 80 | Linux PREEMPT_RT SCHED_FIFO 80 (same) |
| EtherCAT (IgH master) | SCHED_FIFO 90, PREEMPT_RT | Same IgH driver, SCHED_FIFO 90 (RTnet not used) |
| Build complexity | Standard | Requires Dovetail patches for BCM2712 |
| RPi5 stability | Well-tested | Community Dovetail patches — not validated on this board |
| Recommended for | Standard motion control (tested) | Future: high-speed / many-axis once libcobalt integrated |

> The Xenomai build is a **work in progress**. Use PREEMPT_RT for production. The Xenomai target exists to enable future integration of `xenomai-libcobalt` once a scarthgap-compatible layer is available.

To build the Xenomai target (experimental):
1. Obtain Dovetail patches (see [INSTALLATION.md](INSTALLATION.md))
2. Run `./cclrte.sh build xenomai`
3. Flash: `./cclrte.sh load /dev/sdX xenomai`
4. All CODESYS programs and configs carry over (same `/var/opt/codesys` partition)

---

## Validation Status

What has been physically tested on RPi5 hardware and what has not.

### ✅ Tested and verified

| Feature | Result |
|---------|--------|
| **CODESYS Control for Linux SL** | Runtime installs, starts, and is visible to IDE via Scan Network |
| **CODESYS IDE connection** | Online → Scan Network finds device; Download and Run work |
| **RT latency (idle)** | Cyclictest worst-case **11 µs** on CPU3 (SCHED_FIFO 90, 500 µs interval, 30 s) — no PLC program running; under real scan-cycle load not yet tested |
| **RT configuration** | CPU3 affinity (0x8), isolcpus=2,3, sched_rt_runtime_us=-1, performance governor — all verified on hardware |
| **WebUI — Dashboard** | All cards load: service status, network IPs, RT result, hardware stats, PLC load bars, clock, CODESYS runtime |
| **WebUI — Live CPU/memory load** | Bars update every 2 s correctly |
| **WebUI — Clock & Time Sync** | Pi clock displays and updates every second; NTP badge reflects real sync state (no false positives) |
| **WebUI — Timesync page** | Timezone selection applies immediately; Method A/B/C selection saves and shows on dashboard |
| **WebUI — Sync Time Now** | Reports real result — success with offset, or specific failure reason (no internet route, etc.) |
| **WebUI — Network page** | eth0/wlan0 reconfiguration; SSH key injection |
| **WebUI — CODESYS page** | Service start/stop; log viewer; cycle time display |
| **WebUI — System page** | Reboot; RT verify trigger; password change |
| **NTP time sync (Method A)** | chrony syncs to Cloudflare/Google over WiFi; correct time persists in RTC across reboots |
| **Routing isolation** | eth0 has no default gateway; NTP/internet traffic routes via wlan0 only |
| **SSH access** | Root login on eth0 and wlan0 (password + key) |
| **WiFi management** | wlan0 DHCP via wpa_supplicant; credentials set from site.conf |
| **Watchdog** | Service runs; BCM2712 hardware watchdog active |

### ❌ Not yet tested (hardware not available during development)

| Feature | Notes |
|---------|-------|
| **RT latency under PLC load** | Cyclictest run idle only; worst-case latency with a real CODESYS program running (scan cycle + I/O) not yet measured |
| **CODESYS Cycle Time Monitor** | Runtime starts and IDE connects; no PLC program downloaded and run yet |
| **EtherCAT (IgH master)** | Service builds and installs; fieldbus operation with real slaves not tested — requires USB-to-Ethernet NIC and EtherCAT hardware |
| **IO-Link** | Recipe builds; physical HAT and devices not tested |
| **CAN bus (MCP2515)** | `can-utils` installed; no CAN HAT tested |
| **RS-485 / Modbus RTU** | UART0 configured; no RS-485 HAT tested |
| **PROFINET device (p-net)** | Recipe builds; no PROFINET controller or hardware tested |
| **OPC-UA (open62541)** | Library builds and links; end-to-end client connection not tested |
| **MQTT (Mosquitto)** | Broker installs; publish/subscribe with external client not tested |
| **NTP Method B (PC as NTP server)** | W32tm configuration documented; end-to-end sync over eth0 not tested on hardware |
| **NTP Method C (PTP IEEE 1588)** | `linuxptp` not yet in image; grandmaster setup not tested |
| **Xenomai Cobalt** | Build infrastructure in place; `xenomai-libcobalt` userspace not yet included (no scarthgap meta-xenomai layer); Dovetail patches for BCM2712 are community-maintained and not validated on this board |
| **Hardware RTC (PCF85063A)** | `rtcsync` in chrony config; RTC persistence across cold power-off not explicitly tested |

> Features marked ❌ are **build-complete** — the recipes exist, packages install, and services start. They are untested due to missing hardware, not missing software. Treat them as unvalidated until tested with real devices.

---

## Watchdog Behavior

The hardware watchdog (BCM2712) has a 15-second hardware timeout. The watchdog daemon kicks it every 2 seconds with a 10-second software timeout.

If the system locks up or `codesyscontrol` hangs the kernel:
- After 10 seconds without a watchdog kick, the daemon triggers a soft reboot
- If the system is completely unresponsive, BCM2712 performs a hard reset at 15 seconds
- The system reboots automatically
- `codesyscontrol.service` restarts and resumes the last downloaded PLC program

The systemd service uses `Restart=on-failure` so if `codesyscontrol` exits unexpectedly it is restarted automatically after 5 seconds.
