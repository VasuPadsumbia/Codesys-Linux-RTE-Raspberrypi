# CODESYS Control Linux RTE
<!-- Author: Vasu Padsumbia -->

[![Build QEMU Image](https://github.com/yourusername/yocto-gateway-rt/actions/workflows/build.yml/badge.svg)](https://github.com/yourusername/yocto-gateway-rt/actions/workflows/build.yml)
[![Unit Tests](https://github.com/yourusername/yocto-gateway-rt/actions/workflows/test.yml/badge.svg)](https://github.com/yourusername/yocto-gateway-rt/actions/workflows/test.yml)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE)

A Yocto-based real-time Linux distribution for the **Raspberry Pi 5 (2 GB)** that runs **CODESYS Control for Linux SL** as a deterministic industrial PLC. Designed for motion control, machine automation, and industrial IoT applications with cycle times down to 500 µs. A Xenomai Cobalt build target is included and running on hardware — **worst-case RT latency 11 µs** measured under full CPU load.

---

## Features

- **Hard real-time kernel** — PREEMPT_RT / Xenomai Cobalt with HZ=1000, isolated CPUs 2 and 3 for EtherCAT and CODESYS; **verified 11 µs worst-case** under stress-ng load
- **Xenomai Cobalt build** — dual-kernel running on hardware (`6.6.63-cclrte-xenomai`); `xenomai-libcobalt` userspace pending
- **CODESYS Control for Linux SL** — industry-standard IEC 61131-3 runtime; IDE connects via Scan Network; 500 µs cycle confirmed on Core 3
- **IgH EtherCAT master** v1.6.9 — kernel-space EtherCAT master (`ec_master.ko`, `ec_generic.ko`) pinned to CPU2, SCHED_FIFO 90
- **OPC-UA** — open62541 v1.3.10 server/client, port 4840
- **MQTT** — Mosquitto broker with WebSocket support
- **PROFINET device** — p-net stack (slave mode); controller requires CODESYS PROFINET SL
- **IO-Link master** — iol (rt-labs), SPI0, 4 ports
- **Modbus/RS-485** — via CODESYS SL on PL011 UART0
- **WebUI** — Flask-based configuration dashboard, port 8080, dark industrial theme; includes time sync configuration page with timezone selector and three sync methods (Internet NTP / PC LAN / PTP)
- **Deterministic networking** — eth0 static 192.168.2.100 (CODESYS programming, no default gateway), wlan0 DHCP (management + internet + NTP)
- **NTP time sync** — chrony with Cloudflare/Google servers; configurable to sync from engineering PC over eth0 for airgapped deployments; timezone selectable in WebUI
- **Hardware watchdog** — BCM2712 15 s timeout, auto-reboots on runtime hang
- **RT latency verification** — 3-phase cyclictest on CPU2 (EtherCAT) + CPU3 (CODESYS), ~3 min, triggered from WebUI
- **KAS build system** — reproducible Yocto builds with shared sstate-cache
- **CI/CD** — GitHub Actions QEMU build + unit test pipeline

---

## Build Targets

| Target | KAS Config | Latency (avg) | Latency (worst-case, measured) | Cycle Time |
|--------|-----------|---------------|-------------------------------|------------|
| **PREEMPT_RT** (default) | `kas/rpi5-64.yml` | < 30 µs | < 100 µs | 500 µs |
| **Xenomai Cobalt** *(experimental)* | `kas/rpi5-xenomai.yml` | CPU2: 9 µs / CPU3: 11 µs | **11 µs** (verified on RPi5 hardware) | 500 µs |
| **QEMU CI** | `kas/qemu-x86-64.yml` | N/A | N/A | CI only |

The Xenomai build is running on hardware with confirmed 11 µs worst-case latency under stress-ng load. `xenomai-libcobalt` userspace (RTDM tasks) is not yet integrated — CODESYS and EtherCAT run as Linux `SCHED_FIFO` threads, which delivers the measured 11 µs result on isolated cores.

---

## Live System — Verified on Hardware

All screenshots below are from a Raspberry Pi 5 Model B Rev 1.1 running `6.6.63-cclrte-xenomai` (2026-06-09).

### WebUI Dashboard

![Dashboard — all services ACTIVE, EtherCAT running on CPU2, CODESYS on CPU3, RT PASS 11 µs, NTP synced](docs/images/Webui%20Dashboard.png)

All five services active (Codesys, Ethercat, Webui, Mosquitto, Watchdog), RT latency **PASS — 11 µs** worst-case, NTP offset 0.3 ms, CPU temp 52.9 °C (fan-control holding 50–60 °C band). CPU3 shows 80 % load — the FB_LoadTest function block is running at 100 % capacity on the isolated core. CPU2 (EtherCAT) stays at 0 %, confirming the two real-time cores are isolated from each other and from OS tasks on CPU0/1.

### Industrial Protocols

![Protocols page — EtherCAT ACTIVE on CPU2 SCHED_FIFO 90 with ec_generic, MAC auto-detected from eth1](docs/images/Webui%20Industrial%20Communication%20configuration.png)

EtherCAT master service **ACTIVE** on the Waveshare PCIe NIC (`eth1`), CPU2 SCHED_FIFO 90, `ec_generic` driver. MAC auto-populated at first boot. PROFINET and Modbus TCP are built and present but inactive — only one fieldbus protocol may be active on eth1 at a time.

### RT Latency Verification

![System page — cyclictest PASS, CPU2 EtherCAT and CPU3 CODESYS latency breakdown, idle + load phases](docs/images/Webui%20System%20configuration.png)

Two-phase cyclictest (idle 30 s + stress-ng load 30 s). Results on isolated cores:

| Core | Load avg (µs) | Verdict |
|------|--------------|---------|
| CPU2 — EtherCAT FIFO 90 | 9 | ✅ PASS |
| CPU3 — CODESYS FIFO 80 | **11** | ✅ PASS |

Threshold: 100 µs. Kernel: `6.6.63-cclrte-xenomai`.

---

## Hardware Requirements

| Component | Requirement |
|-----------|-------------|
| SBC | Raspberry Pi 5 **2 GB RAM** (tested and validated) |
| SD card | 16 GB minimum, Class 10 / UHS-I or better |
| Power supply | 5 V 5 A USB-C (official RPi5 PSU required) |
| Cooling | Active (heatsink + fan) — CPU runs at 2.4 GHz continuously (`force_turbo=1`) |
| EtherCAT NIC | **Waveshare PCIe TO Gigabit ETH Board (C)** (RTL8111H, PCIe x1 HAT+ FPC) — fitted as eth1, dedicated to fieldbus |
| IO-Link | IO-Link HAT over SPI0 (iol-compatible, 4 ports) |
| CAN | MCP2515 HAT or equivalent over SPI |
| RS-485 | RS-485 HAT on UART0 (`/dev/ttyAMA0`) |

See [docs/INSTALLATION.md](docs/INSTALLATION.md) for detailed hardware notes.

---

## Quick Start

### 1. Clone

```bash
git clone https://github.com/yourusername/yocto-gateway-rt.git
cd yocto-gateway-rt
```

### 2. Configure site settings

```bash
cp config/site.conf.sample config/site.conf
# Edit config/site.conf — set WiFi credentials, SSH key, hostname
nano config/site.conf
```

### 3. Build

```bash
# Default: PREEMPT_RT for RPi5
./cclrte.sh build preempt-rt

# Alternative: Xenomai Cobalt (requires Dovetail patches — see docs/INSTALLATION.md)
./cclrte.sh build xenomai

# CI/testing: QEMU x86-64 (no hardware required)
./cclrte.sh build qemu
```

First build takes 4–8 hours. Subsequent builds use sstate-cache and are much faster.

### 4. Flash SD card

```bash
# Insert SD card, identify device (e.g. /dev/sdb — NOT /dev/sda)
./cclrte.sh load /dev/sdb preempt-rt

# For Xenomai build
./cclrte.sh load /dev/sdb xenomai
```

The script automatically copies `config/site.conf` to the boot partition after flashing.

### 5. First boot

Insert SD card into RPi5, power on. On first boot `network-firstboot.sh` reads `/boot/site.conf` and configures:
- eth0 static 192.168.2.100/24 (CODESYS programming port)
- wlan0 with your WiFi credentials (management/WebUI)
- SSH authorized key
- Hostname

SSH access (after first boot):
```bash
ssh root@192.168.2.100     # via Ethernet
# or
ssh root@<wlan0-ip>        # via WiFi (check router DHCP table)
# Default password: cclrte
```

### 6. CODESYS runtime (auto-installed on first boot)

CODESYS Control for Linux SL is a **closed-license commercial product**. Place both packages in `data/` **before** building:

```bash
ls data/
# codesyscontrol_linuxarm64_4.20.0.0_arm64.deb   ← runtime binary
# codesyscontrol_linuxarm64_4.20.0.0_arm64.ipk   ← component libraries
# Obtain from: CODESYS IDE → Help → Install CODESYS Control for Linux
#           or from https://store.codesys.com
```

The packages are bundled into the image and installed automatically on first boot via `codesys-firstboot.service`. No manual step required after flashing.

### 7. Connect CODESYS IDE

Once port 1217 is listening (`ss -tlnp | grep 1217`):

1. **Online → Scan Network** — the `cclrte-plc` device appears automatically
2. Double-click the device → **Login** (leave blank — UserMgmt disabled by default)
3. **Online → Download** your PLC project

---

## Directory Structure

```
yocto-gateway-rt/
├── kas/                        # KAS build configurations
│   ├── base.yml               # Shared repos and settings
│   ├── rpi5-64.yml            # PREEMPT_RT RPi5 build
│   ├── rpi5-xenomai.yml       # Xenomai Cobalt RPi5 build
│   └── qemu-x86-64.yml        # QEMU CI build
├── layers/
│   └── meta-cclrte/           # Custom Yocto layer
│       ├── conf/
│       │   ├── distro/        # cclrte distro config
│       │   └── machine/       # rpi5-cclrte, rpi5-cclrte-xenomai
│       └── recipes-*/         # All custom recipes
│           └── recipes-codesys/codesys-control/files/
│               ├── config/    # CODESYSControl.cfg, CODESYSControl_User.cfg, rt-override.conf
│               ├── services/  # systemd units and .path files
│               ├── scripts/   # shell scripts (install, setup, firstboot, post-install)
│               └── shims/     # dpkg/apt-get shims for Yocto compatibility
├── config/
│   └── site.conf.sample       # First-boot configuration template
├── docs/
│   ├── INSTALLATION.md
│   ├── ARCHITECTURE.md
│   ├── USER_GUIDE.md
│   └── LIMITATIONS.md
├── tests/
│   ├── unit/                  # pytest unit tests
│   ├── qemu/                  # QEMU boot/RT tests
│   └── integration/           # On-target integration tests
├── .github/workflows/         # CI/CD
├── cclrte.sh                  # Main management script
├── requirements.txt           # Python deps (kas, pytest, flask, ...)
└── LICENSE                    # MIT + third-party licenses
```

---

## Documentation

| Document                                     | Description                                            |
|----------------------------------------------|--------------------------------------------------------|
| [docs/INSTALLATION.md](docs/INSTALLATION.md) | Hardware setup, build steps, flashing, CODESYS install |
| [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) | System design, CPU layout, RT stack, network topology  |
| [docs/USER_GUIDE.md](docs/USER_GUIDE.md)     | WebUI usage, CODESYS programming, day-to-day operation |
| [docs/LIMITATIONS.md](docs/LIMITATIONS.md)   | Known constraints, licensing notes, PROFINET limits    |
| [docs/REQUIREMENTS_AND_KNOWN_ISSUES.md](docs/REQUIREMENTS_AND_KNOWN_ISSUES.md) | Exact hardware/software versions, all real errors encountered and their confirmed fixes |

---

## Testing

```bash
# Unit tests (no hardware required)
./cclrte.sh test

# QEMU boot test (requires QEMU build)
bash tests/qemu/run_qemu_test.sh

# On-target integration tests (run on RPi via SSH)
bash tests/integration/test_codesys_startup.sh
bash tests/integration/test_ethercat.sh
```

### CODESYS Runtime — Load Test (on hardware)

The `FB_LoadTest` function block measures how much computation the CODESYS scan cycle can sustain on the isolated core. It runs a floating-point loop guarded by a cycle-time watchdog so it never misses the 500 µs deadline.

**Variable watch — FB_LoadTest at 100 % load:**

![CODESYS IDE variable watch — xEnable TRUE, uiLoadPercent 100, udiIterations 100000, xOverrun FALSE, udiElapsedMs 0, lrResult accumulating](docs/images/Codesys%20Load%20Test%20configuration.png)

At `uiLoadPercent = 100`, `udiBaseIterations = 1000`:
- `udiIterations = 100 000` — all iterations completed within the 500 µs cycle
- `xOverrun = FALSE` — the 400 µs cycle guard was never triggered
- `udiElapsedMs = 0` — 100 k iterations complete in ~400 µs (< 1 ms, rounds to 0)
- `udiCycleCounter = 78 635` — ~39 s of stable runtime at capture time
- `lrResult = 678 917.91...` — accumulating FP sum, confirming every iteration ran

**Task Configuration Monitor — cycle time under 100 % load:**

![CODESYS Task Configuration Monitor — Task Valid, configured 500 µs, last 391 µs, average 372 µs, max 402 µs, Core 3](docs/images/Codesys%20Load%20Test%20Results.png)

| Metric | Value |
|--------|-------|
| Configured cycle | 500 µs |
| Last cycle time | 391 µs |
| Average cycle time | **372 µs** |
| **Max cycle time** | **402 µs** |
| Max jitter | ±48 µs |
| Core | **3** (isolated, SCHED_FIFO 80) |

The CODESYS runtime enforces the 500 µs boundary strictly — 100 000 FP iterations complete in ≤ 402 µs worst-case, leaving ~98 µs for runtime overhead (PDO exchange, communication stack). The kernel RT guarantee of 11 µs ensures this margin is never eroded by OS jitter.

> **Calibration:** `udiBaseIterations = 1000` gives a linear 0–100 % load range on the RPi5 Cortex-A76 (4 ns/iteration → 400 µs at 100 %). See [docs/USER_GUIDE.md — CPU Load Testing](docs/USER_GUIDE.md#cpu-load-testing) for the full function block reference and tuning guide.

---

## License

This project is MIT licensed. See [LICENSE](LICENSE) for full text and third-party component licenses.

**CODESYS Control for Linux SL** is a commercial product by CODESYS GmbH and is governed by the CODESYS End-User License Agreement. It is **not** included in this repository.
