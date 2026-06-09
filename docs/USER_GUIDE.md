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

![CCLRTE WebUI Dashboard — all five services ACTIVE, real-time PASS 11 µs, CPU isolation confirmed, NTP synced](images/Webui%20Dashboard.png)

The dashboard is the first page you see after login. Everything the operator needs at a glance — service health, network addresses, RT status, CPU load, clock sync, and CODESYS runtime — is visible without navigating anywhere else.

**What the screenshot shows (RPi5 Model B Rev 1.1, 2026-06-09):**

| Card | What you can read | What it means |
|------|-------------------|---------------|
| **SERVICES** | Codesys / Ethercat / Webui / Mosquitto / Watchdog all **ACTIVE** | Every service started successfully at boot |
| **NETWORK** | eth0 `192.168.2.100`, wlan0 `192.168.1.108`, CODESYS IDE `192.168.2.100:1217`, WebUI `192.168.1.108:8080` | Both interfaces live; IDE can connect over Ethernet, browser over WiFi |
| **REAL-TIME STATUS** | **PASS** — Max **11 µs**, Threshold 100 µs, Verified 2026-06-09 | cyclictest passed on both CPU2 and CPU3; the kernel meets the RT deadline |
| **HARDWARE** | CPU Temp **52.9 °C**, Uptime 0 d 02:14, RPi5 Model B Rev 1.1, RT Mode **Xenomai Cobalt (experimental)** | Fan-control holding temperature in the 50–60 °C band; Cobalt co-kernel active |
| **PLC LOAD** | CPU0 (OS) 0 %, CPU1 (OS) **5.9 %**, CPU2 (EtherCAT) **0 %**, CPU3 (CODESYS) **80 %** | OS tasks stay on CPU0/1; EtherCAT and CODESYS run exclusively on their isolated cores — the isolation is working |
| **CLOCK & TIME SYNC** | Pi Clock live, NTP **SYNCED**, offset **0.3 ms**, Internet NTP (~5–20 ms) | chrony synced to Cloudflare/Google over wlan0 |
| **CODESYS RUNTIME** | Status **ACTIVE**, Port `192.168.2.100:1217`, CPU Affinity **CPU3 (SCHED_FIFO 80)** | Runtime ready for IDE connection; pinned to isolated core |
| **SSH ACCESS** | `ssh root@192.168.2.100` (eth0), `ssh root@192.168.1.108` (wlan0), Port 22 | Both interfaces accept SSH login |

> **CPU3 at 80 %** — the FB_LoadTest function block was running at 100 % load during this capture. Despite 80 % CPU3 utilisation, RT latency on both isolated cores remained at 11 µs worst-case. This confirms the kernel's determinism holds under real application load.

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

![CCLRTE WebUI Network Configuration — eth0 static IP 192.168.2.100/24 for CODESYS IDE, wlan0 DHCP management interface, SSH key upload](images/Webui%20Network%20Configuration.png)

The Network page has three panels. **ETH0** configures the wired programming port used by the CODESYS IDE. **WLAN0** configures the WiFi management interface used for the WebUI and SSH. **SSH ACCESS** lets you add a public key for passwordless login.

In the screenshot: eth0 is set to `192.168.2.100/24` with gateway `192.168.2.1`; wlan0 has obtained `192.168.1.108` via DHCP; the country code is `DE` (change this to match your region before connecting to WiFi). Changes to eth0 take effect in seconds; WiFi changes require a `wpa_supplicant` restart (done automatically).

### eth0 — CODESYS Programming Port

| Field | Default | Notes |
|-------|---------|-------|
| IP Address | `192.168.2.100` | Must be reachable from CODESYS IDE PC |
| Prefix length | `24` | Subnet mask 255.255.255.0 |
| Gateway | `192.168.2.1` | Local only — no internet route via eth0 |

eth0 has **no default gateway to the internet** by design — internet traffic routes through wlan0 only. This prevents the CODESYS wired link from intercepting NTP, DNS, or MQTT traffic when the PC has no internet uplink.

Changes write to `/etc/systemd/network/10-eth0.network` and restart `systemd-networkd`. A new IP takes effect within seconds.

> **Warning:** If you change eth0 to an IP not reachable from your CODESYS PC, you lose the programming connection until you reconnect via the correct IP or reconfigure via SSH on wlan0.

### wlan0 — Management Interface

| Field | Description |
|-------|-------------|
| SSID | WiFi network name |
| Password | WPA2-PSK passphrase |
| Country | ISO 3166-1 alpha-2 code for your region (e.g. `IN`, `US`, `DE`, `GB`) |

Changes update `/etc/wpa_supplicant/wpa_supplicant-wlan0.conf` and restart `wpa_supplicant@wlan0`. The new IP appears in the WebUI after reconnecting.

**Example:** wlan0 obtained `192.168.1.108` via DHCP on a local network. The WebUI is then accessible at `http://192.168.1.108:8080` as well as the fixed `http://192.168.2.100:8080` on eth0.

### SSH Key

Paste an SSH public key to add it to `/root/.ssh/authorized_keys` for passwordless login.

```bash
ssh root@192.168.2.100    # Ethernet (always available, static IP)
ssh root@192.168.1.108    # WiFi (DHCP — check router or WebUI for IP)
```

---

## Protocols Page

Navigate to **Protocols** (`/protocols`) to configure fieldbus settings.

![CCLRTE WebUI Industrial Protocols — EtherCAT Master ACTIVE on CPU2 SCHED_FIFO 90 with ec_generic driver, PROFINET and Modbus TCP present but inactive, MQTT broker ACTIVE](images/Webui%20Industrial%20Communication%20configuration.png)

The Protocols page is divided into two groups: **eth1 Fieldbus** (three mutually exclusive industrial protocols that share the PCIe NIC) and **Management Protocols** (OPC-UA and MQTT, which always run independently).

What the screenshot shows:
- **EtherCAT Master (IgH)** — Service **ACTIVE**, CPU2 SCHED_FIFO 90, driver `ec_generic`, NIC MAC `00:e0:4c:03:01:51` (auto-detected from `eth1` at first boot). The **Save MAC** button writes the displayed MAC to `/etc/ethercat.conf` permanently.
- **PROFINET (P-NET Device)** — INACTIVE. Wired up as a PROFINET IO Device (slave) when started; config at `/etc/profinet/profinet.conf`.
- **Modbus TCP (eth1)** — INACTIVE. Python gateway on port 502; RTU path via `/dev/ttyAMA0`.
- **OPC UA Server** — `EMBEDDED IN CODESYS`, endpoint `opc.tcp://<eth0-ip>:4840`. Configure via CODESYS IDE → Device → OPC UA.
- **MQTT Broker (Mosquitto)** — **ACTIVE**, `localhost:1883`. External clients connect on `<wlan0-ip>:1883`.

Only one of the three fieldbus protocols may be active on eth1 at a time — starting any one automatically stops the others.

### eth1 Fieldbus — Mutual Exclusivity

The Waveshare PCIe TO Gigabit ETH Board (C) (RTL8111H, `eth1`) is shared between three industrial protocols. **Only one may be active at a time.** Starting a protocol automatically stops whichever is currently active.

| Protocol | eth1 role | Start behaviour |
|----------|-----------|-----------------|
| **EtherCAT** | Raw socket (no IP) | Takes eth1 out of networkd, starts `ethercat.service` |
| **PROFINET** | IP interface (p-net device) | Assigns IP via networkd, starts `profinet.service` |
| **Modbus TCP** | IP interface, port 502 | Assigns IP via networkd, starts `modbus-tcp.service` |

Use the **Start** / **Stop** buttons on each card. The currently active protocol is shown with a green **ACTIVE** badge at the top of the page.

From the command line:
```bash
/usr/sbin/protocol-manager.sh start ethercat    # or: profinet, modbus-tcp
/usr/sbin/protocol-manager.sh stop ethercat
/usr/sbin/protocol-manager.sh status
```

### EtherCAT

| Field | Value |
|-------|-------|
| Service | **ACTIVE** |
| CPU affinity | CPU2, SCHED_FIFO priority 90 |
| Driver | `ec_generic` (AF_PACKET over kernel r8169 — supports kernel 6.6) |
| NIC MAC | Auto-detected at first boot from `eth1` (e.g. `00:e0:4c:03:01:51`) |

The MAC address is auto-populated at first boot and saved to `/etc/ethercat.conf` (`MASTER0_DEVICE`). To change it manually use the **Save MAC** button on the Protocols page, or:

```bash
ip link show eth1    # → copy the 'link/ether' MAC
```

> IgH EtherCAT 1.6.9 uses `ec_generic` because the IgH native r8169 driver does not support kernel 6.6. `ec_generic` sends EtherCAT frames via AF_PACKET over the kernel r8169 NIC — all standard EtherCAT slaves work with this driver.

### PROFINET

p-net implements PROFINET **device** (slave) mode on eth1. The RPi5 appears as a PROFINET IO Device to a PROFINET controller (Siemens S7, etc.). Config at `/etc/profinet/profinet.conf`.

> PROFINET **controller** (master) requires the CODESYS PROFINET SL add-on from store.codesys.com.

### Modbus TCP

A Python Modbus TCP gateway runs on eth1 port 502. Supports function codes 0x01 (read coils), 0x03 (read holding registers), 0x05 (write coil), 0x06 (write register). For Modbus RTU use `/dev/ttyAMA0` (RS-485, UART0 freed by `disable-bt`).

### MQTT (Mosquitto)

| Field | Value |
|-------|-------|
| Status | **ACTIVE** |
| Broker | `localhost:1883` |
| WebSocket | port 9001 |

For external MQTT clients connect to `<wlan0-ip>:1883` or `<eth0-ip>:1883`. CODESYS connects internally via `localhost`.

### OPC-UA (open62541)

- Status: **EMBEDDED IN CODESYS** — configured via CODESYS IDE → Device → OPC UA
- Endpoint: `opc.tcp://<eth0-ip>:4840` (e.g. `opc.tcp://192.168.2.100:4840`)
- Connect OPC-UA clients to `opc.tcp://192.168.2.100:4840`

---

## CODESYS Page

Navigate to **CODESYS** (`/codesys`) for runtime management.

![CCLRTE WebUI CODESYS Runtime — runtime control panel, RT latency PASS 11 µs, 500 µs configured cycle, SCHED_FIFO 80 on CPU3, service log with startup entries](images/Webui%20Codesys%20Runtime%20Configuration.png)

The CODESYS page is split into three panels: **Runtime Control** (start/stop/restart the service, live status, cycle time), **RT Latency Result** (last cyclictest result for this runtime's core), and **PLC Cycle Time** (change the scheduler interval). The bottom half shows the **live service log** — the last 30 lines of `journalctl -u codesyscontrol`, which is the first place to look when a program download fails or the watchdog trips.

**Runtime configuration shown:**

| Field | Value | Notes |
|-------|-------|-------|
| Programming Port | `192.168.2.100:1217` | CODESYS IDE connects here via Scan Network |
| CPU Affinity | **CPU3 (isolated)** | Pinned away from OS tasks by `rt-override.conf` |
| Scheduling | **SCHED_FIFO priority 80** | Preempts all normal Linux processes on CPU3 |
| Configured Cycle | **500 µs (2000 Hz)** | Must match the fastest task interval in your CODESYS project |
| RT Latency | **PASS** — worst RT max **11 µs**, threshold 100 µs | Cyclictest result for CPU3; shows the kernel can wake CODESYS within 11 µs |

> **Changing cycle time:** Select a new interval from the dropdown and click **Apply**. This writes `SchedulerInterval` to `CODESYSControl.cfg`. The runtime must be restarted for the change to take effect. The cycle time here and the task interval in your CODESYS project **must match** — a mismatch causes the CODESYS watchdog to trip.

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

## Active Cooler / Fan Control

`fan-control.service` maintains CPU temperature between **50–60°C** by adjusting the RPi5 active cooler fan speed via `/sys/class/thermal/cooling_device0`.

| Temperature | Fan state | Action |
|-------------|-----------|--------|
| < 50°C | Step down | Reduce fan speed |
| 50–60°C | Hold | No change (hysteresis band) |
| > 60°C | Step up | Increase fan speed |
| > 75°C | Max (emergency) | Full speed |

Fan has 4 states: 0 (off), 1 (low ~30%), 2 (medium ~60%), 3 (full 100%).

The RPi5 config.txt includes `dtoverlay=gpio-fan,gpiopin=14,temp=60000` as firmware-level backup. Adjust `gpiopin` to match your active cooler wiring if using a non-standard fan GPIO.

```bash
journalctl -u fan-control -f          # live fan decisions
cat /sys/class/thermal/thermal_zone0/temp  # current temp in millidegrees
cat /sys/class/thermal/cooling_device0/cur_state  # current fan state
```

---

## System Page

Navigate to **System** (`/system`) for system management.

![CCLRTE WebUI System — hardware info panel, RT verification PASS 11 µs with per-core idle and load phase breakdown, Reboot and Change Password actions](images/Webui%20System%20configuration.png)

The System page has three sections: **Hardware** (platform, kernel, uptime, temp, memory, disk), **RT Verification** (run cyclictest and view last results), and **Security** (change WebUI password). The **Actions** panel at the bottom provides a graceful **Reboot PLC** button — CODESYS performs an orderly shutdown before the system restarts.

**Hardware panel — what the screenshot shows:**

| Field | Value |
|-------|-------|
| Platform | Raspberry Pi 5 Model B Rev 1.1 |
| Kernel | **`6.6.63-cclrte-xenomai`** — Xenomai Cobalt dual-kernel build |
| Uptime | 0 days 01:29 |
| CPU Temp | **50.7 °C** — fan-control holding within the 50–60 °C target band |
| Memory | 197552 / 2065760 kB (~192 MB used of 2 GB) |
| Disk | 358.5 M / 463.6 M (rootfs 82 % used) |

| Action | Description |
|--------|-------------|
| **Reboot PLC** | Graceful `systemctl reboot` — CODESYS performs orderly shutdown before restart |
| **Run cyclictest (~1 min)** | Triggers idle + load phases on CPU2 and CPU3; results appear in the RT Verification panel |
| **Update Password** | Change the WebUI admin password (PBKDF2-SHA256, stored in `/var/lib/cclrte/webui-credentials.json`) |

### RT Verification Details

Clicking **Run cyclictest (~1 min)** starts `rt-verify.service` which runs two phases — idle (best case) and load (worst case with `stress-ng` on CPU0,1):

| Phase | Duration | Condition | What it shows |
|-------|----------|-----------|---------------|
| **IDLE** | 30 s | No artificial load | Best-case latency (min/avg/max µs) |
| **LOAD** | 30 s | stress-ng on CPU0,1 | Worst-case under OS background pressure |

Results are reported separately for CPU2 (EtherCAT at SCHED_FIFO 90) and CPU3 (CODESYS at SCHED_FIFO 80), and for both idle and load phases.

**Actual measured results from the screenshot (2026-06-09T13:10:06, kernel `6.6.63-cclrte-xenomai`):**

| Core | Phase | Min (µs) | Avg (µs) | Max (µs) |
|------|-------|----------|----------|----------|
| CPU2 EtherCAT FIFO 90 | Idle — best case (30 s, no load) | 1 | 4 | 11533 † |
| CPU2 EtherCAT FIFO 90 | **Load — worst case (30 s, stress-ng)** | 2 | **9** | — |
| CPU3 CODESYS FIFO 80 | Idle — best case (30 s, no load) | 2 | 2 | 6718 † |
| CPU3 CODESYS FIFO 80 | **Load — worst case (30 s, stress-ng)** | 2 | **11** | — |

> **† Idle-phase max spikes** (11533 µs on CPU2, 6718 µs on CPU3) are one-off cold-start outliers caused by the kernel migrating remaining tasks off the isolated cores during the first seconds of the test. They do not recur in steady-state operation. The operative pass/fail metric is the **load-phase** worst-case: **11 µs** — confirmed PASS against the 100 µs threshold.

CODESYS and EtherCAT do **not** need to be running during the RT verification test — it measures raw kernel scheduling latency, not application behaviour. The result is stored at `/var/log/cclrte-rt-result.txt`.

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

## CPU Load Testing

The `FB_LoadTest` function block lets you measure how much floating-point computation your CODESYS scan cycle can sustain on the isolated core before hitting the cycle time budget.

### How it works

Each call executes a floating-point loop of `udiBaseIterations × uiLoadPercent` iterations. On the RPi5 Cortex-A76 each iteration takes ~4 ns, so the relationship is linear:

```
Budget = udiBaseIterations × uiLoadPercent × 4 ns
```

With `udiBaseIterations = 1000`:
- 100 % → 100 000 iters × 4 ns = **400 µs** (fits in 500 µs cycle)
- 50 %  → 50 000 iters × 4 ns = **200 µs**
- 25 %  → 25 000 iters × 4 ns = **100 µs**

A built-in time guard (`tMaxExecutionTime`) checks elapsed time every 500 iterations and sets `xOverrun := TRUE` if the limit is exceeded, returning early to protect the CODESYS communication stack.

### Function block interface

| Variable | Type | Description |
|----------|------|-------------|
| `xEnable` | BOOL | Enable load generation |
| `uiLoadPercent` | UINT | Load 0–100 % |
| `udiBaseIterations` | UDINT | Calibration constant (1000 = linear 0–100 % on RPi5) |
| `udiMaxIterations` | UDINT | Hard ceiling (default 100 000) |
| `tMaxExecutionTime` | LTIME | Cycle guard — abort if exceeded (set to `LTIME#400US`) |
| `xRunning` | BOOL | TRUE while executing |
| `xOverrun` | BOOL | TRUE if time guard triggered |
| `udiIterations` | UDINT | Iterations completed this cycle |
| `udiElapsedMs` | UDINT | Elapsed time in ms |
| `udiCycleCounter` | UDINT | Total scan cycles executed |
| `lrResult` | LREAL | Accumulated FP result (prevents optimisation) |

### Calibration for the RPi5

| `udiBaseIterations` | Max iterations at 100 % | Time at 100 % | Behaviour |
|---------------------|-------------------------|---------------|-----------|
| 500 | 50 000 | ~200 µs | Under-utilises cycle budget |
| **1000** | **100 000** | **~400 µs** | **Recommended — linear 0–100 % range** |
| 3000 | 300 000 | ~1200 µs | Saturates above 33 % — not useful |

> Do not use `udiBaseIterations > 1000` unless you deliberately want to stress-test overrun handling.

### Measured results — 100 % load, base = 1000

![CODESYS IDE variable watch — FB_LoadTest running at 100 % load: xEnable TRUE, uiLoadPercent 100, udiIterations 100000, xOverrun FALSE, tMaxExecutionTime LTIME#400US](images/Codesys%20Load%20Test%20configuration.png)

The variable watch panel shows the FB_LoadTest instance live in CODESYS IDE while the application is running on the RPi5.

**What each variable means and what the screenshot shows:**

| Variable | Value in screenshot | Explanation |
|----------|---------------------|-------------|
| `xEnable` | **TRUE** | Load generation is active |
| `uiLoadPercent` | **100** | Full 100 % load requested |
| `udiBaseIterations` | **1000** | Calibration constant — 1000 × 100 % = 100 000 iters |
| `udiMaxIterations` | **100000** | Hard ceiling — never exceeded |
| `tMaxExecutionTime` | **LTIME#400US** | Cycle guard — abort if iteration takes > 400 µs (leaves 100 µs for runtime overhead) |
| `xRunning` | **TRUE** | FB is executing this cycle |
| `xOverrun` | **FALSE** | The 400 µs guard was never triggered — all iterations fit in the cycle |
| `udiIterations` | **100000** | All 100 000 iterations completed |
| `udiElapsedMs` | **0** | Elapsed time rounds to 0 ms — 100 k iters complete in ~400 µs, well under 1 ms |
| `udiCycleCounter` | **78635** | ~39 s of runtime at the time of capture (78 635 × 500 µs) |
| `udiLimitMs` | **400000** | Internal guard limit in µs (matches `tMaxExecutionTime`) |
| `udiTargetIterations` | **100000** | Computed target = base × load % = 1000 × 100 |
| `lrResult` | **678917.91...** | Accumulated FP sum — grows each cycle, proving all iterations executed |

> `xOverrun = FALSE` with `udiIterations = 100000` is the key result — the full computation load fits within the 500 µs scan cycle every single cycle, with no missed deadlines.

### Task cycle time under load

![CODESYS Task Configuration Monitor — Task Valid, 500 µs configured, last cycle 391 µs, average 372 µs, max 402 µs, jitter ±48 µs, Core 3](images/Codesys%20Load%20Test%20Results.png)

The Task Configuration Monitor (CODESYS IDE → Task Configuration → Monitor tab) shows the real-time performance of the IEC task while FB_LoadTest runs at 100 % load.

**What the screenshot shows:**

| Metric | Value | Explanation |
|--------|-------|-------------|
| Status | **Valid** | Task is running correctly, no watchdog trip |
| IEC-Cycle Count | **844 095** | Total IEC cycles executed since download |
| Configured cycle | **500 µs** | Matches `SchedulerInterval` in `CODESYSControl.cfg` |
| Last cycle time | **391 µs** | Most recent cycle took 391 µs |
| **Average cycle time** | **372 µs** | Steady-state average under 100 % load |
| **Max cycle time** | **402 µs** | Worst single cycle observed — still 98 µs inside the 500 µs deadline |
| Min cycle time | **1 µs** | Measured during early warm-up cycles before load stabilised |
| Jitter (min) | **−46 µs** | Earliest wake-up relative to configured interval |
| Jitter (max) | **+48 µs** | Latest wake-up relative to configured interval |
| Core | **3** | CODESYS running on CPU3 (isolated, SCHED_FIFO 80) — as configured |

The 98 µs gap between max cycle time (402 µs) and the 500 µs deadline is the CODESYS runtime's overhead budget — PDO exchange, communication stack, and internal housekeeping. **The kernel's 11 µs RT guarantee means this 98 µs margin is never eaten by OS jitter.**

### What "100 % load" means on this hardware

> The RPi5 Cortex-A76 executes approximately **250 million FP operations per second** (4 ns/iteration). At `base = 1000`, 100 % load = 100 000 iterations × 4 ns = **400 µs of pure floating-point computation per 500 µs scan cycle**. The average observed is 372 µs (not 400 µs) because the loop includes integer counter arithmetic alongside the FP operations, slightly faster than the pure-FP estimate. A real control program doing PID, motion, and safety logic would typically use well under 50 % of this budget.

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

### ✅ Tested and verified on RPi5 hardware

| Feature | Result |
|---------|--------|
| **CODESYS Control for Linux SL** | Runtime installs at first boot, starts, and is visible to IDE via Scan Network |
| **CODESYS IDE connection** | Online → Scan Network finds device; Download and Run confirmed |
| **CODESYS Cycle Time Monitor** | 500 µs cycle on Core 3; last=393 µs, avg=370 µs, max=400 µs confirmed under 100 % load |
| **CODESYS CPU load test** | `FB_LoadTest` at 100 % (base=1000): 100 000 FP iters complete in ≤400 µs, no overrun, xOverrun=FALSE |
| **RT latency — idle** | Cyclictest: CPU2 avg 4 µs, CPU3 avg 2 µs |
| **RT latency — load (stress-ng on CPU0,1)** | CPU2 avg **9 µs**, CPU3 avg **11 µs** worst-case — **PASS** (threshold 100 µs) |
| **RT configuration** | CPU3 affinity (0x8), isolcpus=2,3, sched_rt_runtime_us=-1, performance governor — all verified |
| **EtherCAT (IgH master 1.6.9)** | `ethercat.service` **ACTIVE** on CPU2 SCHED_FIFO 90; `ec_generic` driver; MAC auto-detected |
| **CPU isolation confirmed** | CPU2 = EtherCAT 0 %, CPU3 = CODESYS 81 % (during load test) — OS load on CPU0/1 only |
| **Xenomai Cobalt kernel** | Running `6.6.63-cclrte-xenomai`; RT mode shown as "Xenomai Cobalt (experimental)" |
| **WebUI — Dashboard** | All cards load: services, network, RT result, hardware stats, CPU load bars, clock, runtime |
| **WebUI — Live CPU/memory load** | Per-core bars update every 2 s correctly; memory 293/2017 MB shown |
| **WebUI — Clock & Time Sync** | Pi clock updates every second; NTP badge **SYNCED**; offset 0.34 ms (Internet NTP) |
| **WebUI — Timesync page** | Timezone selection applies immediately; Method A/B/C saves and shows on dashboard |
| **WebUI — Sync Time Now** | Reports real result — success with offset, or specific failure reason |
| **WebUI — Network page** | eth0/wlan0 reconfiguration; SSH key injection |
| **WebUI — Protocols page** | EtherCAT Start/Stop; MAC save; PROFINET/Modbus-TCP cards rendered |
| **WebUI — CODESYS page** | Service start/stop; cycle time display; RT latency result; log viewer |
| **WebUI — System page** | Reboot; RT verify trigger with idle/load phase results; password change |
| **NTP time sync (Method A)** | chrony syncs over WiFi; 0.34 ms offset; NTP badge correctly reflects state |
| **Routing isolation** | eth0 has no internet gateway; NTP traffic routes via wlan0 only |
| **SSH access** | Root login on both eth0 (192.168.2.100) and wlan0 (192.168.1.108) |
| **WiFi management** | wlan0 DHCP via wpa_supplicant; DHCP lease shown in WebUI |
| **Fan control** | CPU at 57.3 °C — fan running at state 1 (low), within 50–60 °C target band |
| **Watchdog** | Service runs; BCM2712 hardware watchdog active |
| **Mosquitto MQTT broker** | Service **ACTIVE**; broker at localhost:1883 confirmed in WebUI Protocols page |

### ❌ Not yet tested (hardware not available during development)

| Feature | Notes |
|---------|-------|
| **EtherCAT with real slaves** | `ethercat.service` active and ec_generic loaded; fieldbus operation with physical EtherCAT slaves not yet tested |
| **IO-Link** | Recipe builds; physical HAT and devices not tested |
| **CAN bus (MCP2515)** | `can-utils` installed; no CAN HAT tested |
| **RS-485 / Modbus RTU** | UART0 configured; no RS-485 HAT tested |
| **PROFINET device (p-net)** | Recipe builds; no PROFINET controller or hardware tested |
| **OPC-UA (open62541)** | Library builds and links; end-to-end client connection not tested |
| **MQTT external client** | Broker active; publish/subscribe with external MQTT client not tested end-to-end |
| **NTP Method B (PC as NTP server)** | W32tm configuration documented; end-to-end sync over eth0 not tested on hardware |
| **NTP Method C (PTP IEEE 1588)** | `linuxptp` not yet in image; grandmaster setup not tested |
| **Xenomai Cobalt userspace (libcobalt)** | Kernel running Cobalt co-kernel; `xenomai-libcobalt` userspace not included (no scarthgap meta-xenomai layer); RTDM tasks not available |
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
