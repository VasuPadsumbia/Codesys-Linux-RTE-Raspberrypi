# Limitations
<!-- Author: Vasu Padsumbia -->

Known constraints, licensing requirements, and trade-offs of the cclrte platform.

---

## Real-Time Performance

### PREEMPT_RT Latency Bounds

PREEMPT_RT is a fully preemptible kernel with typical worst-case latency of **< 50 µs** on RPi5 under normal conditions. However:

- **Worst-case can reach 200+ µs** under extreme IRQ load (USB storms, WiFi activity, SD card writes)
- **No hard guarantee** — PREEMPT_RT is a best-effort RT approach. The isolation of CPUs 2,3 mitigates most sources, but cannot eliminate all
- **Recommended minimum cycle time: 500 µs** for reliable operation
- Run `cyclictest` under your actual workload (EtherCAT traffic, MQTT activity, WiFi connected) to characterize latency in your environment

If cyclictest shows `worst_max_us` > 100 µs under production workload, switch to the Xenomai build.

### WiFi Interference

WiFi (CYW43455) generates interrupt bursts that can cause latency spikes on CPU0/1. The `rt-setup.sh` script moves all IRQs to CPU0,1 away from the RT domain, but WiFi interrupt storms can still briefly raise OS jitter. For latency-critical deployments, disable wlan0 and use only eth0 + a serial console.

### EtherCAT NIC (Waveshare PCIe RTL8111H)

The **Waveshare PCIe TO Gigabit ETH Board (C)** (RTL8111H) is a native PCIe x1 Gen2 NIC connected via HAT+ FPC connector — it is **not** a USB device and does not add USB interrupt overhead. Measured EtherCAT latency on CPU2: **9 µs avg** under stress-ng load (2026-06-09 on RPi5). This NIC is suitable for EtherCAT applications with cycle times ≥ 500 µs.

For applications requiring sub-100 µs EtherCAT bus cycle with many slaves, consider an RTDM-capable driver (requires `libcobalt` integration — see Xenomai Cobalt section below).

---

## Xenomai Cobalt

### BCM2712 / RPi5 Build — Verified on Hardware

The Xenomai Cobalt build (`rpi5-cclrte-xenomai`, kernel `6.6.63-cclrte-xenomai`) is **verified running on Raspberry Pi 5 Model B Rev 1.1** as of 2026-06-09:

- **Build succeeded** — 5214/5214 tasks, both `ec_master.ko` and `ec_generic.ko` IPKs generated
- **RT latency verified** — cyclictest two-phase (idle 30 s + stress-ng load 30 s): **CPU2 EtherCAT avg 9 µs, CPU3 CODESYS avg 11 µs worst-case** under full CPU load — well below 100 µs threshold
- **CODESYS running** — `codesyscontrol` service ACTIVE, 500 µs cycle, SCHED_FIFO 80 on CPU3

However, two aspects remain incomplete:

- **`xenomai-libcobalt` userspace** — not yet integrated in `meta-cclrte`. CODESYS and EtherCAT run as Linux `SCHED_FIFO` threads (not Cobalt RTDM tasks). The 11 µs result is achieved by CPU isolation + Linux SCHED_FIFO, not the Cobalt hard-RT domain.
- **EtherCAT on Cobalt** — IgH EtherCAT is built with `ec_generic` (Linux domain) rather than the RTDM driver. For full Cobalt hard-RT EtherCAT, `libcobalt` integration is required.

The delivered RT performance (11 µs worst-case under load) is adequate for ≥ 500 µs scan cycle applications without libcobalt.

### Build Prerequisite Not Automated

Dovetail kernel patches must be placed in `layers/meta-cclrte/recipes-kernel/linux-xenomai/files/patches/` manually before running `./cclrte.sh build xenomai`. KAS does not fetch them automatically.

### Xenomai Userspace Requirements

CODESYS Control for Linux SL is a closed-source binary linked against glibc — it cannot use the Cobalt POSIX skin directly. It runs in the Linux domain with `SCHED_FIFO 80` on isolated CPU3. Integration with `libcobalt` for RTDM-capable components (e.g. EtherCAT master) remains a pending enhancement.

---

## CODESYS Licensing

### Binary Not Included

CODESYS Control for Linux SL is a **closed-source commercial product** by CODESYS GmbH. It is governed by the CODESYS End-User License Agreement and is **not distributed with this project**.

You must:
1. Purchase or obtain an evaluation license from [store.codesys.com](https://store.codesys.com) — download both the `.deb` (runtime binary) and `.ipk` (component libraries) packages
2. Place **both files** in `data/` at the repo root before running `./cclrte.sh build`

```bash
ls data/
# codesyscontrol_linuxarm64_4.20.0.0_arm64.deb
# codesyscontrol_linuxarm64_4.20.0.0_arm64.ipk
```

The packages are bundled into the image and installed automatically on first boot via `codesys-firstboot.service`. The CODESYS IDE "Update Raspberry Pi" wizard uses `dpkg` and checks `/proc/cpuinfo` for ARMv7 — **both fail on Yocto arm64** — do not use it.

### Runtime License Activation

CODESYS Control for Linux SL requires license activation via the CODESYS Development System or a CODESYS License Manager. Without an active license, the runtime runs in demo mode (limited program size, stops after 2 hours). Consult CODESYS GmbH documentation for license deployment.

### Add-On Licenses

Several protocol implementations require additional CODESYS SL add-ons:

| Feature             | Status                                      |
|---------------------|---------------------------------------------|
| EtherCAT master     | Included in CODESYS Control SL              |
| OPC-UA server       | CODESYS OPC UA Server SL (separate license) |
| PROFINET controller | CODESYS PROFINET SL (separate license)      |
| CANopen master      | CODESYS CANopen SL (separate license)       |
| Modbus              | Included in CODESYS Control SL              |

---

## PROFINET

### Device Mode Only

The `p-net` (rt-labs) library included in this build implements **PROFINET IO device** (slave) mode. The RPi5 appears as a PROFINET IO device to a PROFINET controller (e.g. Siemens S7-1200/1500, Beckhoff TwinCAT).

**PROFINET IO controller** (master) — directing other PROFINET IO devices — requires the **CODESYS PROFINET SL** add-on, which is not included.

### PROFINET RT Timing

p-net supports PROFINET RT (cycle class A, 1 ms minimum cycle time). PROFINET IRT (isochronous real-time, < 1 ms) is not supported by p-net and would require dedicated hardware.

---

## IO-Link

### 4-Port SPI0 Limit

The `iol` (rt-labs) driver is configured for **4 ports on SPI0**. Expanding beyond 4 ports or using additional SPI buses requires:
- Driver source modification
- Additional IO-Link HATs with SPI chip selects
- Device tree overlay updates

### Vendor Interoperability

IO-Link device profiles (IODD files) are device-specific. Configure IODD files in CODESYS for each connected device. iol provides the transport layer only; application-layer interpretation is done by CODESYS.

---

## Storage

### SD Card Wear

Consumer SD cards have limited write endurance (~10,000 cycles per cell). PLC systems write logs and program state continuously. For production deployments:
- Use industrial-grade SD cards (rated for extended temperature and write cycles)
- Consider log rotation limits (set in journald.conf)
- The RPi5 CM5 with eMMC storage is a better option for production

### No Redundancy

The cclrte platform is a single-point-of-failure system:
- No redundant power supply
- No hot-swap storage
- No failover node

For safety-critical or high-availability applications, implement system-level redundancy (redundant PLCs with heartbeat) at the application layer.

---

## Networking

### MQTT Without TLS

Mosquitto is configured without TLS by default. MQTT traffic between CODESYS and external clients is unencrypted. For production:

```
# /etc/mosquitto/mosquitto.conf additions:
listener 8883
certfile /etc/mosquitto/certs/server.crt
keyfile /etc/mosquitto/certs/server.key
cafile /etc/mosquitto/certs/ca.crt
require_certificate true
```

### OPC-UA Without Certificate Infrastructure

open62541 is built without a full PKI certificate infrastructure. The OPC-UA server operates in unencrypted mode by default. Enable security policies in the CODESYS OPC-UA server configuration if required by your security policy.

### eth0 No Firewall

The eth0 interface (CODESYS programming) has no firewall rules by default. It is assumed to be on a private, dedicated programming network. If eth0 is exposed to a shared network, add `iptables` rules to allow only port 1217 (gateway) and 4840 (OPC-UA).

---

## Build System

### First Build Time

First build requires downloading all sources (poky, meta-openembedded, kernel, packages) and compiling from source. Expect **4–8 hours** on an 8-core host machine with a fast internet connection.

### Sstate-cache Invalidation

Changing `MACHINE`, `DISTRO`, or core recipe versions invalidates the sstate-cache. After a cache invalidation, the next build approaches first-build time. Use `./cclrte.sh clean recipes [target]` to invalidate only meta-cclrte recipes while preserving the upstream cache.

### KAS Version Compatibility

KAS configuration format version 14 (`header.version: 14`) requires KAS >= 4.0. Older KAS versions will reject the configuration files.

---

## Summary Table

| Limitation                                         | Severity   | Status / Workaround                                         |
|----------------------------------------------------|------------|-------------------------------------------------------------|
| PREEMPT_RT max latency > 100 µs possible           | Medium     | Use Xenomai build (verified 11 µs worst-case on RPi5)       |
| WiFi IRQ interference on OS cores                  | Low        | Disable wlan0 for latency-critical deployments              |
| Xenomai libcobalt userspace not integrated         | Low-Medium | CODESYS/EtherCAT run as Linux SCHED_FIFO — 11 µs verified   |
| EtherCAT no physical slave tested                 | Low        | Service ACTIVE; test with slave hardware to confirm PDO     |
| CODESYS binary not included                        | High       | Obtain from store.codesys.com; deploy via `install-codesys-runtime.sh` |
| PROFINET controller not supported                  | Medium     | Requires CODESYS PROFINET SL add-on                         |
| PROFINET / Modbus-TCP mutually exclusive with EtherCAT on eth1 | Low | Use `protocol-manager.sh`; only one active at a time   |
| IO-Link limited to 4 ports (SPI0)                 | Low        | Modify iol driver for more ports / buses                    |
| No MQTT TLS by default                             | Medium     | Configure Mosquitto with certificates                       |
| No OPC-UA PKI by default                           | Medium     | Configure in CODESYS OPC-UA server settings                 |
| SD card wear                                       | Medium     | Use industrial SD or eMMC (CM5)                             |
