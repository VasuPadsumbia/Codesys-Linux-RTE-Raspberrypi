# CODESYS Control Linux RTE
<!-- Author: Vasu Padsumbia -->

[![Build QEMU Image](https://github.com/yourusername/yocto-gateway-rt/actions/workflows/build.yml/badge.svg)](https://github.com/yourusername/yocto-gateway-rt/actions/workflows/build.yml)
[![Unit Tests](https://github.com/yourusername/yocto-gateway-rt/actions/workflows/test.yml/badge.svg)](https://github.com/yourusername/yocto-gateway-rt/actions/workflows/test.yml)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE)

A Yocto-based real-time Linux distribution for the **Raspberry Pi 5 (2 GB)** that runs **CODESYS Control for Linux SL** as a deterministic industrial PLC. Designed for motion control, machine automation, and industrial IoT applications with cycle times down to 500 µs (PREEMPT_RT) or 250 µs (Xenomai Cobalt).

---

## Features

- **Hard real-time kernel** — PREEMPT_RT with HZ=1000, isolated CPUs 2 and 3 for EtherCAT and CODESYS
- **Xenomai Cobalt upgrade path** — dual-kernel option achieving 2–15 µs worst-case latency
- **CODESYS Control for Linux SL** — industry-standard IEC 61131-3 runtime (IDE deploys it over SSH)
- **IgH EtherCAT master** v1.5.2 — kernel-space EtherCAT master pinned to CPU2, SCHED_FIFO 90
- **OPC-UA** — open62541 v1.3.10 server/client, port 4840
- **MQTT** — Mosquitto broker with WebSocket support
- **PROFINET device** — p-net stack (slave mode); controller requires CODESYS PROFINET SL
- **IO-Link master** — iol (rt-labs), SPI0, 4 ports
- **Modbus/RS-485** — via CODESYS SL on PL011 UART0
- **WebUI** — Flask-based configuration dashboard, port 8080, dark industrial theme
- **Deterministic networking** — eth0 static 192.168.2.100 (CODESYS programming), wlan0 DHCP (management)
- **Hardware watchdog** — BCM2712 15 s timeout, auto-reboots on runtime hang
- **RT latency verification** — 3-phase cyclictest on CPU2 (EtherCAT) + CPU3 (CODESYS), ~3 min, triggered from WebUI
- **KAS build system** — reproducible Yocto builds with shared sstate-cache
- **CI/CD** — GitHub Actions QEMU build + unit test pipeline

---

## Build Targets

| Target | KAS Config | Latency (typical) | Latency (worst-case) | Cycle Time |
|--------|-----------|-------------------|----------------------|------------|
| **PREEMPT_RT** (default) | `kas/rpi5-64.yml` | < 30 µs | < 100 µs | 500 µs |
| **Xenomai Cobalt** | `kas/rpi5-xenomai.yml` | 2–5 µs | 2–15 µs | 250 µs |
| **QEMU CI** | `kas/qemu-x86-64.yml` | N/A | N/A | CI only |

Start with PREEMPT_RT. Upgrade to Xenomai if cyclictest shows worst-case > 100 µs under your workload.

---

## Hardware Requirements

| Component | Requirement |
|-----------|-------------|
| SBC | Raspberry Pi 5 **2 GB RAM** (tested and validated) |
| SD card | 16 GB minimum, Class 10 / UHS-I or better |
| Power supply | 5 V 5 A USB-C (official RPi5 PSU required) |
| Cooling | Active (heatsink + fan) — CPU runs at 2.4 GHz continuously (`force_turbo=1`) |
| EtherCAT NIC | USB-to-Ethernet adapter (RTL8152 or AX88179) connected as eth1 — dedicated to fieldbus |
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

---

## License

This project is MIT licensed. See [LICENSE](LICENSE) for full text and third-party component licenses.

**CODESYS Control for Linux SL** is a commercial product by CODESYS GmbH and is governed by the CODESYS End-User License Agreement. It is **not** included in this repository.
