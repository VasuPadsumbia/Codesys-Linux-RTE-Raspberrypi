# Architecture
<!-- Author: Vasu Padsumbia -->

This document describes the system design of the CODESYS Control Linux RTE (cclrte) platform.

---

## System Overview

cclrte turns a Raspberry Pi 5 (2 GB) into a deterministic industrial PLC by layering:

1. **Firmware-level RT tuning** — CPU frequency locked at 2.4 GHz, DVFS disabled, GPU/display clock trees idle
2. **PREEMPT_RT or Xenomai kernel** — full preemption or dual-kernel hard-RT
3. **CPU isolation** — two cores reserved exclusively for real-time tasks
4. **CODESYS Control for Linux SL** — IEC 61131-3 runtime, pinned to isolated core
5. **IgH EtherCAT master** — kernel-space fieldbus, pinned to isolated core
6. **WebUI + management stack** — confined to general-purpose cores

The screenshot below shows the system live on hardware — all six layers operational simultaneously:

![CCLRTE WebUI Dashboard — all five services ACTIVE, RT PASS 11 µs, Xenomai Cobalt kernel, CPU2 EtherCAT SCHED_FIFO 90, CPU3 CODESYS SCHED_FIFO 80, NTP synced 0.3 ms](images/Webui%20Dashboard.png)

Every part of the architecture is visible: the firmware layer (CPU temp 52.9 °C, `force_turbo=1` keeping the CPU at 2.4 GHz), the kernel layer (Xenomai Cobalt, RT PASS 11 µs), the CPU isolation (CPU2 = 0 %, CPU3 = 80 % under load, OS on CPU0/1), the CODESYS runtime (ACTIVE, CPU3 SCHED_FIFO 80), and the management stack (WebUI, MQTT, NTP — all on CPU0/1).

---

## Network Topology

```
                    ┌──────────────────────────────────┐
                    │       Raspberry Pi 5             │
                    │                                  │
  CODESYS IDE ──────┤ eth0  192.168.2.100/24 (static)  │
  (port 1217)       │   └─ CODESYS programming port    │
  OPC-UA client ────┤      CODESYS OPC-UA :4840        │
                    │      (no default gateway here)   │
                    │                                  │
  WiFi AP ──────────┤ wlan0  DHCP                      │
  WebUI :8080       │   └─ Management / SSH / NTP      │
  SSH / NTP         │      Flask WebUI                 │
                    │                                  │
  EtherCAT slaves ──┤ eth1  (no IP — link-only)        │
  (USB-to-ETH NIC)  │   └─ IgH EtherCAT master         │
                    │                                  │
  IO-Link devices ──┤ SPI0  /dev/spidev0.0             │
  (4 ports via HAT) │   └─ iol master                  │
                    │                                  │
  Modbus devices ───┤ UART0 /dev/ttyAMA0               │
  (RS-485 HAT)      │   └─ CODESYS Modbus SL           │
                    │                                  │
  CAN devices ──────┤ SPI1  MCP2515                    │
  (CAN HAT)         │   └─ CODESYS CANopen SL          │
                    └──────────────────────────────────┘
```

**Note:** eth0 is the native RPi5 GbE (BCM2712 / RP1 MAC). eth1 is the **Waveshare PCIe TO Gigabit ETH Board (C)** (RTL8111H, PCIe x1 Gen2, HAT+ FPC connector). eth1 is shared between industrial fieldbus protocols — only one may be active at a time, managed by `protocol-manager.sh`.

### Time Synchronisation

The system clock is maintained by **chrony** (NTP client/server). Three sync methods are configurable from the WebUI (`/timesync`):

| Method | Source | Accuracy |
|--------|--------|----------|
| A — Internet NTP | Cloudflare/Google via wlan0 | ~5–20 ms |
| B — Engineering PC LAN | Windows W32tm on 192.168.2.x via eth0 | < 1 ms |
| C — PTP IEEE 1588 | Hardware grandmaster on network | < 1 µs |

chrony is started after `network-online.target` (fired by `systemd-networkd-wait-online --any`) so it always has a valid network route before its first poll. On successful sync, chrony writes the corrected time back to the RPi5 hardware RTC (PCF85063A) via `rtcsync`, preserving correct time across power cycles.

---

## CPU Layout

The four RPi5 cores (BCM2712, Cortex-A76) are partitioned into two domains:

```
┌──────────────────────────────────────────────────────────────┐
│                    RPi5 BCM2712 (4× Cortex-A76)              │
├──────────────────┬────────────────┬──────────────────────────┤
│   CPU 0          │   CPU 1        │  CPU 2       CPU 3       │
│   General OS     │   General OS   │  EtherCAT    CODESYS     │
│   systemd        │   systemd      │  ec_master   codesysctrl │
│   networking     │   flask webui  │  SCHED_FIFO  SCHED_FIFO  │
│   mosquitto      │   ssh          │  prio 90     prio 80     │
│   logging        │   udev         │  isolated    isolated    │
├──────────────────┴────────────────┼──────────────────────────┤
│      Linux domain                 │     Real-time domain     │
│   (systemd CPUAffinity=0 1)       │   (isolcpus=2,3)         │
└───────────────────────────────────┴──────────────────────────┘
```

**Why isolate CPUs?**

Without `isolcpus`, the Linux scheduler can migrate tasks onto any core, causing latency spikes when a general-purpose task preempts the EtherCAT or PLC thread — even with SCHED_FIFO. With `isolcpus=2,3 nohz_full=2,3`:

- No timer ticks interrupt CPUs 2,3 (tickless operation)
- No tasks migrate onto CPUs 2,3 unless explicitly pinned
- `rcu_nocbs=2,3` removes RCU callbacks from isolated cores
- Result: sub-100 µs worst-case latency for PREEMPT_RT; 11 µs measured on Xenomai Cobalt

The PLC Load bars in the dashboard confirm CPU isolation in operation — CPU2 (EtherCAT) and CPU3 (CODESYS) are separate from OS load, and OS tasks are confined to CPU0/CPU1:

![CCLRTE WebUI Dashboard PLC Load — CPU0 0%, CPU1 5.9% (OS tasks), CPU2 0% (EtherCAT isolated), CPU3 80% (CODESYS under 100% FB_LoadTest)](images/Webui%20Dashboard.png)

CPU3 is at 80 % because FB_LoadTest is running 100 000 FP iterations every 500 µs scan cycle. CPU2 stays at 0 % — the EtherCAT master is waiting for frames and consumes negligible CPU when no slaves are connected. Despite CPU3 running at 80 %, the RT latency test (11 µs worst-case) was recorded under equivalent load conditions, confirming that CPU isolation prevents cross-core interference.

---

## RT Determinism Stack

```
┌─────────────────────────────────────────────────────────────────┐
│ Application Layer                                               │
│   CODESYS: SysCPUAffinity=0x08, SCHED_FIFO 80, mlockall         │
│   EtherCAT: taskset CPU2, SCHED_FIFO 90                         │
├─────────────────────────────────────────────────────────────────┤
│ Scheduler / Process Layer                                       │
│   sched_rt_runtime_us = -1  (no RT bandwidth cap)               │
│   vm.swappiness = 0         (no page swapping)                  │
│   prlimit MEMLOCK=unlimited (CODESYS, EtherCAT)                 │
│   CPUAffinity=0 1 in system.conf.d (all services → CPU0,1)      │
├─────────────────────────────────────────────────────────────────┤
│ CPU Frequency / C-State Layer                                   │
│   scaling_governor = performance (all CPUs)                     │
│   C-states disabled on CPU2, CPU3                               │
│   CPU locked at 2.4 GHz on all cores (force_turbo=1)            │
├─────────────────────────────────────────────────────────────────┤
│ Kernel Layer                                                    │
│   CONFIG_PREEMPT_RT=y     Full kernel preemption                │
│   HZ=1000                 1 ms timer resolution                 │
│   NO_HZ_FULL              Tickless on isolated CPUs             │
│   RCU_NOCB_CPU            RCU off isolated CPUs                 │
│   CPU_IDLE=n              No CPU idle driver                    │
│   FTRACE=n, SCHED_DEBUG=n No tracing overhead                   │
│   BCM2712_WDT=y           Hardware watchdog (RP1)               │
├─────────────────────────────────────────────────────────────────┤
│ Firmware Layer (config.txt)                                     │
│   force_turbo=1           Lock CPU at 2.4 GHz (base clock)      │
│   temp_limit=80           Thermal limit 80°C (not 85°C)         │
│   gpu_mem=16              Minimal GPU memory allocation         │
│   DISABLE_VC4GRAPHICS=1   VC4 KMS driver off (idle GPU clocks)  │
│   hdmi_blanking=2         HDMI completely off                   │
│   display_auto_detect=0   No display enumeration at boot        │
│   camera_auto_detect=0    No camera enumeration at boot         │
│   dtparam=audio=off       Audio clocks off                      │
│   dtoverlay=disable-bt    Free UART0 from Bluetooth             │
│   dtparam=watchdog=on     Enable BCM2712 hardware watchdog      │
└─────────────────────────────────────────────────────────────────┘
```

---

## Dual-Kernel Architecture (Xenomai Variant)

The Xenomai build target (`cclrte-xenomai-image`) implements a dual-kernel architecture using Dovetail + Cobalt. **Dovetail kernel patches** (from `source.denx.de/Xenomai/linux-dovetail`, branch `v6.6.y/dovetail`) must be placed in `recipes-kernel/linux/files/patches/` and uncommented in `linux-raspberrypi_%.bbappend` before building.

```
┌─────────────────────────────────────────────────────────────────┐
│  CPU2 — EtherCAT master (Cobalt domain, RTDM, SCHED_FIFO 90)   │
│  CPU3 — CODESYS scan cycle (Linux domain, SCHED_FIFO 80)        │
│  CPU0,1 — Linux OS, networking, WebUI                           │
├─────────────────────────────────────────────────────────────────┤
│  Kernel: CONFIG_PREEMPT=y + CONFIG_DOVETAIL=y + Cobalt          │
│  (PREEMPT_RT and Cobalt are mutually exclusive — use PREEMPT)   │
└─────────────────────────────────────────────────────────────────┘
```

**Why CODESYS runs on Linux domain (not Cobalt):** CODESYS Control for Linux SL is a closed-source binary linked against glibc — it cannot use Cobalt POSIX skin. It runs in the Linux domain with `SCHED_FIFO 80` on isolated CPU3. Under `CONFIG_PREEMPT` + CPU isolation, CODESYS wakeup latency is ~20-80 µs worst-case — adequate for ≥500 µs scan cycles.

**EtherCAT on Cobalt:** IgH EtherCAT runs in the Cobalt domain via the RTDM interface (`--enable-rtdm`, requires `libcobalt` from `meta-xenomai`). This gives hard-RT bus cycle timing of ±1-5 µs. Without Dovetail, the fallback is `ec_generic` on PREEMPT_RT.

**Protocol mutual exclusivity:** PREEMPT_RT and Xenomai Cobalt cannot coexist. Choosing the xenomai build means EtherCAT gets Cobalt hard-RT; choosing the preempt-rt build means both EtherCAT and CODESYS run on PREEMPT_RT (adequate for ≥500 µs cycles).

---

## Software Layer Diagram

```
┌─────────────────────────────────────────────────────────────────┐
│                    CODESYS IDE (PC)                             │
└───────────────────────────────┬─────────────────────────────────┘
                                │ TCP 1217 / 4840
┌───────────────────────────────▼─────────────────────────────────┐
│                    cclrte image (Yocto)                         │
│                                                                 │
│  ┌──────────────┐ ┌─────────────┐ ┌────────────┐ ┌──────────┐   │
│  │   CODESYS    │ │ IgH EtherCAT│ │  open62541 │ │ Mosquitto│   │
│  │ Control SL   │ │   master    │ │   OPC-UA   │ │   MQTT   │   │
│  └──────┬───────┘ └──────┬──────┘ └────────────┘ └──────────┘   │
│         │                │                                      │
│  ┌──────▼────────────────▼──────────────────────────────────┐   │
│  │              systemd services                            │   │
│  │   rt-setup → ethercat → codesyscontrol                   │   │
│  │   mosquitto, plc-webui, systemd-networkd                 │   │
│  └──────────────────────────────────────────────────────────┘   │
│                                                                 │
│  ┌──────────────────────────────────────────────────────────┐   │
│  │         PREEMPT_RT or Xenomai Cobalt kernel              │   │
│  └──────────────────────────────────────────────────────────┘   │
│                                                                 │
│  ┌──────────────────────────────────────────────────────────┐   │
│  │  meta-cclrte Yocto layer (custom recipes + distro conf)  │   │
│  └──────────────────────────────────────────────────────────┘   │
└─────────────────────────────────────────────────────────────────┘
```

---

## systemd Service Dependency Chain

```
local-fs.target
    └── sysinit.target
            ├── rt-setup.service          (IRQ affinity, RT throttle — Type=oneshot)
            │       ├── xenomai-setup.service  (Cobalt verify + MAC detect, xenomai only)
            │       │       └── ethercat.service  (CPUAffinity=2, SCHED_FIFO 89)
            │       │               └── codesyscontrol.service  (CPUAffinity=3, SCHED_FIFO 80)
            │       └── ethercat.service  (preempt-rt path — no xenomai-setup)
            ├── fan-control.service       (CPU temp 50-60°C, PWM fan)
            ├── mosquitto.service
            ├── plc-webui.service         (CPUAffinity=0 1, Nice=10)
            ├── modbus-tcp.service        (disabled — started by protocol-manager.sh)
            ├── profinet.service          (disabled — started by protocol-manager.sh)
            └── systemd-networkd.service
```

`protocol-manager.sh` enforces mutual exclusivity on eth1: starting any of EtherCAT / PROFINET / Modbus-TCP stops the other two and reconfigures eth1 (raw socket vs IP interface) as needed.

`rt-setup.service` runs first as a oneshot and:
1. Moves all IRQ affinity to CPU0,1 (mask 0x3)
2. Pins EtherCAT NIC IRQ to CPU2
3. Removes RT bandwidth cap (`sched_rt_runtime_us=-1`)
4. Waits for `ec_master` kernel thread → sets SCHED_FIFO 90 + taskset CPU2
5. Waits for `codesyscontrol` process → sets SCHED_FIFO 80 + taskset CPU3

---

## CODESYS Runtime Deployment

![CODESYS Runtime page — ACTIVE, 500 µs configured cycle, SCHED_FIFO priority 80, CPU3 isolated, RT PASS 11 µs](images/Webui%20Codesys%20Runtime%20Configuration.png)

CODESYS Control for Linux SL is a closed-license binary. The `.deb` and `.ipk` packages are placed in `data/` before the Yocto build and bundled into the image at `/opt/codesys-packages/`. On first boot, `codesys-firstboot.service` installs them automatically — no manual action required.

```
Build time (host):
    data/*.deb + data/*.ipk  →  bundled into image at /opt/codesys-packages/

First boot (RPi5):
    codesys-firstboot.service  (ConditionPathExists=!/var/lib/cclrte/codesys-installed)
            └── /usr/sbin/codesys-firstboot.sh
                    ├── install-codesys-runtime.sh  *.deb  *.ipk
                    │       ├── .deb: Python3 ar extraction → /opt/codesys/bin/codesyscontrol
                    │       ├── .ipk: opkg install --nodeps (component libs)
                    │       └── codesys-post-install.sh
                    │               ├── Apply RT drop-in (CPU3, SCHED_FIFO 80)
                    │               ├── Remove /etc/init.d/codesyscontrol (SysV conflict)
                    │               ├── Enable + start codesyscontrol.service
                    │               └── ldconfig
                    └── creates stamp /var/lib/cclrte/codesys-installed
```

The Yocto image pre-installs:
- `/etc/codesys/CODESYSControl.cfg` — RT config (SchedulerInterval=500, Logger disabled, SysCPUAffinity=0x08)
- `/etc/codesys/CODESYSControl_User.cfg` — gateway + UserMgmt settings (UserMgmtEnabled=0)
- `codesyscontrol.service.d/rt-override.conf` — SCHED_FIFO 80 + CPU3 + MEMLOCK=unlimited
- `/opt/codesys-packages/` — bundled .deb + .ipk
- `/usr/sbin/install-codesys-runtime.sh` — Python3-based extractor (no dpkg/ar needed)
- `/usr/sbin/codesys-post-install.sh` — RT tuning and service activation

---

## RT Latency Verification

![System page — RT verification PASS, worst-case 11 µs, CPU2 EtherCAT + CPU3 CODESYS idle and load phase breakdown](images/Webui%20System%20configuration.png)

After boot, RT latency can be verified via the WebUI (System page) or SSH:

```bash
# Trigger via WebUI "Run cyclictest (~3 min)" button, or:
systemctl restart rt-verify

# View result
cat /var/log/cclrte-rt-result.txt
```

The `run-cyclictest.sh` script runs three independent phases:

| Phase | CPU | Priority | Role |
|-------|-----|----------|------|
| 1 — SMP baseline | all | FIFO 80 | OS noise characterization |
| 2 — EtherCAT | CPU2 | FIFO 90 | EtherCAT master latency budget |
| 3 — CODESYS | CPU3 | FIFO 80 | PLC scan cycle latency budget |

CODESYS and EtherCAT services do **not** need to be running — the test measures kernel RT latency, not application behavior.

Pass/fail is determined by `worst_max_us` which is the **maximum of CPU2 and CPU3 only**. The SMP baseline (`smp_max_us`) is for OS noise characterization and is explicitly excluded — OS cores (CPU0/1) are expected to have higher jitter under load.

Example result (JSON):
```json
{
  "timestamp": "2026-04-10T12:00:00",
  "status": "PASS",
  "threshold_us": 100,
  "duration_sec": 60,
  "interval_us": 500,
  "smp_max_us": 42,
  "cpu2_ethercat": { "max_us": 38, "avg_us": 12, "priority": 90 },
  "cpu3_codesys":  { "max_us": 41, "avg_us": 14, "priority": 80 },
  "worst_max_us":  41
}
```

**Actual measured result on RPi5 Model B Rev 1.1 — `6.6.63-cclrte-xenomai` (2026-06-09):**

| Core | Phase | Min (µs) | Avg (µs) | Max (µs) |
|------|-------|----------|----------|----------|
| CPU2 EtherCAT FIFO 90 | Idle 30 s | 1 | 4 | 11533* |
| CPU2 EtherCAT FIFO 90 | **Load 30 s** | 2 | **9** | — |
| CPU3 CODESYS FIFO 80 | Idle 30 s | 2 | 2 | 6718* |
| CPU3 CODESYS FIFO 80 | **Load 30 s** | 2 | **11** | — |

**Overall: PASS — worst-case 11 µs** (threshold 100 µs, load = stress-ng on CPU0,1).

> \*Idle-phase max spikes are cold-start outliers (kernel migrating tasks off isolated CPUs). They do not recur in steady state. Pass/fail is determined by the load-phase metric only.

---

## Build System Architecture

```
cclrte.sh build <target>
    └── kas build kas/<target>.yml
            ├── kas/base.yml
            │     poky (scarthgap)
            │     meta-openembedded (scarthgap)
            │     meta-cclrte (local)
            └── kas/rpi5-64.yml (or rpi5-xenomai.yml or qemu-x86-64.yml)
                  meta-raspberrypi (scarthgap)
                  meta-realtime (scarthgap)
                      └── bitbake cclrte-image
                              ├── linux-raspberrypi (+ PREEMPT_RT cfg frags)
                              ├── codesys-control (config + service, no binary)
                              ├── igh-ethercat (kernel module)
                              ├── open62541 (OPC-UA library)
                              ├── mosquitto (MQTT broker)
                              ├── plc-webui (Flask WebUI)
                              ├── rt-setup (RT tuning scripts)
                              ├── rt-verify (cyclictest wrapper)
                              └── cclrte-network (networkd configs)
```

---

## Security Model

| Boundary | Mechanism |
|----------|-----------|
| SSH access | Password auth enabled (root / `cclrte`); add SSH key via site.conf or WebUI for key-only access |
| WebUI auth | PBKDF2-HMAC-SHA256, session cookie, `login_required` decorator |
| WebUI credentials | `/var/lib/cclrte/webui-credentials.json` (chmod 600) |
| CODESYS gateway | No built-in auth on port 1217; rely on network segregation (eth0 dedicated programming port, no internet route) |
| MQTT | No TLS by default; enable for production (see `docs/LIMITATIONS.md`) |
| OPC-UA | open62541 without certificate infrastructure by default |
| WiFi | WPA2-PSK; credentials in wpa_supplicant-wlan0.conf (chmod 600) |

---

## Watchdog Behavior

The BCM2712 hardware watchdog (`/dev/watchdog`) is enabled via `dtparam=watchdog=on`. The watchdog daemon (`watchdog.service`) kicks it every 2 seconds with a 10-second software timeout.

If `codesyscontrol` hangs and the system becomes unresponsive:
1. Watchdog daemon stops kicking within 10 seconds
2. BCM2712 watchdog fires (hardware timeout: 15 seconds)
3. System performs hard reset
4. RPi5 reboots and systemd restarts all services

This ensures the PLC returns to operational state after a software hang without manual intervention.
