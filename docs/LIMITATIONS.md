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

### USB EtherCAT NIC Latency

The USB-to-Ethernet adapter (eth1) adds USB interrupt overhead compared to a native PCIe NIC. For applications requiring < 200 µs cycle time with many EtherCAT slaves, consider a carrier board or HAT with a dedicated PCIe or native Ethernet port for EtherCAT.

---

## Xenomai Cobalt

### BCM2712 / RPi5 Dovetail Status

The Xenomai build requires Dovetail interrupt pipeline patches applied to the RPi5 kernel (BCM2712, arm64). As of 2026:

- Dovetail patches for BCM2712 / arm64 are in development and may not be stable for all scarthgap kernel versions
- Compatibility must be verified manually against the actual kernel version before building
- This build target should be considered experimental until upstream Dovetail explicitly supports BCM2712

### Build Prerequisite Not Automated

Dovetail kernel patches must be placed in `layers/meta-cclrte/recipes-kernel/linux-xenomai/files/patches/` manually before running `./cclrte.sh build xenomai`. KAS does not fetch them automatically.

### Xenomai Userspace Requirements

CODESYS Control for Linux SL must be linked against Xenomai's `libcobalt` to run in the Cobalt domain. Verify that your CODESYS version supports Xenomai Cobalt on ARM64 before committing to this build target.

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

| Limitation                                 | Severity   | Workaround                                      |
|--------------------------------------------|------------|-------------------------------------------------|
| PREEMPT_RT max latency > 100 µs possible   | Medium     | Use Xenomai build                               |
| WiFi IRQ interference                      | Low        | Disable wlan0 for critical deployments          |
| USB EtherCAT NIC latency                   | Low-Medium | Use dedicated PCIe/native NIC via HAT           |
| CODESYS binary not included                | High       | Obtain from store.codesys.com; deploy via `install-codesys-runtime.sh` |
| Xenomai Dovetail not yet stable on BCM2712 | High       | Use PREEMPT_RT until upstream support confirmed |
| PROFINET controller not supported          | Medium     | Requires CODESYS PROFINET SL add-on             |
| IO-Link limited to 4 ports                 | Low        | Modify iol driver for more ports                |
| No MQTT TLS by default                     | Medium     | Configure Mosquitto with certificates           |
| No OPC-UA PKI by default                   | Medium     | Configure in CODESYS OPC-UA settings            |
| SD card wear                               | Medium     | Use industrial SD or eMMC (CM5)                 |
