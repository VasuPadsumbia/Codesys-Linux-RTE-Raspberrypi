# Requirements and Known Issues
<!-- Author: Vasu Padsumbia -->

This document captures the exact hardware, software, and library versions used and validated for this project, along with every real error encountered during development and the confirmed fix for each.

---

## Validated Hardware

| Component | Exact Part Used | Notes |
|-----------|----------------|-------|
| **SBC** | Raspberry Pi 5 **2 GB RAM** (BCM2712 / Cortex-A76 quad-core @ 2.4 GHz) | 4 GB / 8 GB variants untested but should work — adjust `BB_NUMBER_THREADS` and `PARALLEL_MAKE` |
| **SD card** | 16 GB Class 10 UHS-I | SanDisk Endurance or Samsung PRO Endurance recommended for production |
| **Power supply** | Official Raspberry Pi 5 USB-C PSU (5 V 5 A / 27 W) | Underpowered PSU causes RT latency spikes and `under-voltage detected` kernel warnings |
| **Cooling** | Raspberry Pi Active Cooler (heatsink + fan) | Required — `force_turbo=1` locks CPU at 2.4 GHz; passive cooling causes thermal throttling and RT jitter |
| **EtherCAT NIC** | USB-to-Ethernet (RTL8152 chipset, e.g. Cable Matters USB 3.0 Gigabit) | Connected as `eth1`; must be dedicated to fieldbus with no IP assigned |
| **Ethernet (programming)** | Standard Cat5e/Cat6 patch cable | Connects RPi5 eth0 to CODESYS programming PC |

### CPU Layout (as configured)

| CPU | Role | Scheduler | Priority | Isolation |
|-----|------|-----------|----------|-----------|
| CPU0, CPU1 | Linux OS, WebUI, SSH, MQTT, OPC-UA | SCHED_OTHER | — | Not isolated |
| CPU2 | EtherCAT master (IgH) | SCHED_FIFO | 90 | `isolcpus=2,3` |
| CPU3 | CODESYS scan cycle | SCHED_FIFO | 80 | `isolcpus=2,3` |

---

## Software Versions

### Build Host

| Software | Version Tested | Notes |
|----------|---------------|-------|
| **Host OS** | Ubuntu 22.04 LTS / Ubuntu 24.04 LTS | Both validated |
| **KAS** | ≥ 4.0 | `pip install kas`; earlier versions lack `header.version: 14` support |
| **Python** | 3.10 / 3.12 | For KAS and WebUI dev |
| **Git** | ≥ 2.34 | Yocto requires git >= 2.28 |

### Yocto / OpenEmbedded

| Component | Version / Branch |
|-----------|-----------------|
| **Yocto release** | **Scarthgap (5.0.x)** |
| **Poky** | `scarthgap` branch |
| **meta-openembedded** | `scarthgap` branch |
| **meta-raspberrypi** | `scarthgap` branch |
| **meta-cclrte** | This repo (`layers/meta-cclrte/`) |
| **LAYERSERIES_COMPAT** | `scarthgap` |
| **Package format** | IPK (`PACKAGE_CLASSES = "package_ipk"`) |

### Kernel

| Item | Value |
|------|-------|
| **Kernel source** | `linux-raspberrypi` (Yocto RPi BSP) |
| **Kernel version** | 6.6.y (matches RPi5 BSP for scarthgap) |
| **Kernel config base** | `bcm2712_defconfig` |
| **RT patch** | `PREEMPT_RT` (full preemption, `preempt=full` kernel cmdline) |
| **Tick rate (HZ)** | 1000 |
| **Kernel cmdline additions** | `isolcpus=2,3 nohz_full=2,3 rcu_nocbs=2,3 threadirqs preempt=full nosoftlockup net.ifnames=0` |
| **Version extension** | `-cclrte-rt` |

For Xenomai Cobalt: requires **Dovetail** interrupt pipeline patches for kernel 6.6.y / BCM2712. Patch availability must be verified against the Xenomai mailing list — not included in this repo.

### CODESYS Runtime

| Item | Value |
|------|-------|
| **Product** | CODESYS Control for Linux SL (ARM64) |
| **Tested version** | **3.5.21.41** (build date Mar 30 2026) |
| **Package (binary)** | `codesyscontrol_linuxarm64_4.20.0.0_arm64.deb` |
| **Package (components)** | `codesyscontrol_linuxarm64_4.20.0.0_arm64.ipk` |
| **License** | Commercial — not included in this repo. Obtain from [store.codesys.com](https://store.codesys.com) or via CODESYS IDE → Help → Install CODESYS Control for Linux |
| **Install path (binary)** | `/opt/codesys/bin/codesyscontrol` |
| **Install path (libs)** | `/opt/codesys/lib/` |
| **Runtime config (live)** | `/etc/codesyscontrol/CODESYSControl.cfg` |
| **Runtime config (backup)** | `/etc/codesys/CODESYSControl.cfg` |
| **User config (live)** | `/etc/codesyscontrol/CODESYSControl_User.cfg` |
| **User config (backup)** | `/etc/codesys/CODESYSControl_User.cfg` |
| **Log file** | `/var/opt/codesys/codesyscontrol.log` (symlinked to `/run/codesys/codesyscontrol.log` on tmpfs) |
| **Programming port** | TCP 1217 |

### Key Libraries and Components (on-device)

| Library / Component | Path | Purpose |
|--------------------|------|---------|
| `libCmpRetain.so` | `/opt/codesys/lib/` | Retain variable persistence across power cycles |
| `libCmpRetainDoubleBufferedInFile.so` | `/opt/codesys/lib/` | Double-buffered retain storage (file-based) |
| `IgH EtherCAT master` | v1.5.2 | Kernel-space EtherCAT master, pinned to CPU2 |
| `open62541` | v1.3.10 | OPC-UA server/client, port 4840 |
| `mosquitto` | Yocto scarthgap default | MQTT broker |
| `p-net` | scarthgap | PROFINET device stack (slave mode) |
| `Flask` | 3.x | WebUI backend |

---

## Key Configuration Parameters

| Parameter | Value | File | Why |
|-----------|-------|------|-----|
| `SchedulerInterval` | `500` (µs) | `CODESYSControl.cfg` | Must match CODESYS task cycle time; wrong value (4000 = default) causes 200–400 µs RT latency spikes on CPU3 |
| `SysCPUAffinity` | `0x08` (bit 3 = CPU3) | `CODESYSControl_User.cfg [SysProcess]` | Bitmask — keeps scan cycle on isolated CPU3 |
| `SchedPolicy` | `SCHED_FIFO` | `CODESYSControl_User.cfg [SysProcess]` | Hard RT scheduling for scan cycle |
| `SchedPriority` | `80` | `CODESYSControl_User.cfg [SysProcess]` | Below EtherCAT (90); above all OS tasks |
| `MemLock` | `YES` | `CODESYSControl_User.cfg [SysProcess]` | `mlockall` — prevents page faults during scan |
| `UserMgmtEnabled` | `0` | `CODESYSControl_User.cfg [CmpUserMgmt]` | Disables login prompt; IDE connects blank |
| `Logger.0.Enable` | `1` | `CODESYSControl.cfg [CmpLog]` | Logs to `/var/opt/codesys/` (symlinked to tmpfs) |
| `Component.0` | `CmpRetain` | `CODESYSControl.cfg [ComponentManager]` | **Must be in primary cfg** — see Known Issue #3 |
| `Linux.DisableCpuDmaLatency` | `1` | `CODESYSControl.cfg [SysCpuHandling]` | Prevents CPU C-states during RT operation |
| `Linux.IPv6` | `0` | `CODESYSControl.cfg [SysSocket]` | Reduces network overhead |
| `force_turbo=1` | — | `/boot/config.txt` (via `RPI_EXTRA_CONFIG`) | Locks CPU at 2.4 GHz; eliminates DVFS latency spikes |

---

## Known Issues and Fixes

### Issue 1 — Yocto `do_install` fails: `.deb`/`.ipk` not found in WORKDIR

**Symptom:**
```
ERROR: codesys-control-1.0-r0 do_install: ...No such file or directory
```
The `.deb` and `.ipk` packages cannot be fetched by Yocto's `file://` fetcher when using a relative path (`../data/`) in `FILESEXTRAPATHS`.

**Root cause:** Yocto's `file://` fetcher resolves paths relative to `FILESPATH` (set by `FILESEXTRAPATHS`) and does not support `../` traversal out of the layer directory.

**Fix:** Remove the packages from `SRC_URI` entirely. Copy them directly in `do_install` using the absolute path `${TOPDIR}/../data/`:
```bitbake
do_install:append() {
    install -d ${D}/opt/codesys-packages
    install -m 0644 \
        ${TOPDIR}/../data/codesyscontrol_linuxarm64_4.20.0.0_arm64.deb \
        ${D}/opt/codesys-packages/
    install -m 0644 \
        ${TOPDIR}/../data/codesyscontrol_linuxarm64_4.20.0.0_arm64.ipk \
        ${D}/opt/codesys-packages/
}
```

---

### Issue 2 — CODESYS log not appearing / wrong log location

**Symptom:** No log file visible; expected log at `/var/log/codesys/` or a path configured via `Logger.0.Path`. CODESYS runtime silently ignores the `Logger.0.Path` key.

**Root cause:** CODESYS always writes `codesyscontrol.log` to its working directory (`/var/opt/codesys/`). The `Logger.0.Path` config key is silently ignored — it does nothing.

**Fix:** Use a symlink to redirect writes to tmpfs (avoids SD card writes while keeping logging enabled):
```bash
# In codesys-setup.sh (runs as ExecStartPre= on every boot):
ln -sf /run/codesys/codesyscontrol.log /var/opt/codesys/codesyscontrol.log 2>/dev/null || true
```
Set `Logger.0.Enable=1` in `CODESYSControl.cfg` so the log is active.

**Log location:** `/var/opt/codesys/codesyscontrol.log` → symlink to `/run/codesys/codesyscontrol.log` (tmpfs, cleared on reboot).

---

### Issue 3 — `Failed to resolve RetainUpdate` / CmpApp init failures / safe mode on every boot

**Symptom:**
```
ERROR: Failed to resolve <name>RetainUpdate</name>
ERROR: Import function(s) failed of <name>CmpApp</name>
#### Exception: Switch to safe mode! Initiator: CM
running in safe mode(~2 hours)
```
Multiple `CmpApp init (N) failed` lines (phases 2, 3, 4, 5, 6, 7, 500) appear — these are all caused by the single unresolved `RetainUpdate` symbol and are not separate errors.

**Root cause:** `libCmpRetain.so` is not loaded by CODESYS. The `[ComponentManager]` section was placed in `CODESYSControl_User.cfg` (loaded via `FileReference`), but **CODESYS only processes `[ComponentManager]` from the primary config file** (`CODESYSControl.cfg`). Entries in FileReference-included files are silently ignored for component loading.

**Confirmed by:** Checking `/proc/<pid>/maps | grep retain` — the library was absent from the running process despite being listed in User.cfg.

**Fix:** Move `[ComponentManager]` to the **primary** `CODESYSControl.cfg`:
```ini
[ComponentManager]
Component.0=CmpRetain
```
Both the primary config (`/etc/codesyscontrol/CODESYSControl.cfg`) and its backup (`/etc/codesys/CODESYSControl.cfg`, which `codesys-setup.sh` copies from on every boot) must contain this section.

**Immediate on-device fix (before rebuilding image):**
```bash
echo "" >> /etc/codesyscontrol/CODESYSControl.cfg
echo "[ComponentManager]" >> /etc/codesyscontrol/CODESYSControl.cfg
echo "Component.0=CmpRetain" >> /etc/codesyscontrol/CODESYSControl.cfg
echo "" >> /etc/codesys/CODESYSControl.cfg
echo "[ComponentManager]" >> /etc/codesys/CODESYSControl.cfg
echo "Component.0=CmpRetain" >> /etc/codesys/CODESYSControl.cfg
systemctl restart codesyscontrol
```

**Verify fix:**
```bash
cat /proc/$(pgrep codesyscontrol)/maps | grep retain   # must show libCmpRetain.so
grep -E "RetainUpdate|safe mode|ready" /var/opt/codesys/codesyscontrol.log | tail -5
# Expected: only "CODESYS Control ready" — no RetainUpdate or safe mode
```

---

### Issue 4 — `codesys-setup.sh` always-overwrite undoes runtime config changes

**Symptom:** Any change made to `/etc/codesyscontrol/CODESYSControl_User.cfg` (e.g., by `cfg_add_cmp.sh` after `.ipk` install) is lost after the next CODESYS restart.

**Root cause:** `codesys-setup.sh` runs as `ExecStartPre=` on every service start and always copies the backup (`/etc/codesys/*.cfg`) over the live configs. This is intentional (prevents IDE reinstall from resetting RT settings) but means the **backup** must be authoritative.

**Fix:** Any permanent change to the live config must also be applied to `/etc/codesys/` (the backup). This is the pattern: the `data/` directory under the repo serves as the source of truth at build time; `/etc/codesys/` on the device is the runtime source of truth.

---

### Issue 5 — Wrong section name `[CmpUserMgr]` breaks IDE login silently

**Symptom:** IDE login is rejected without an error message. Username/password prompt appears even though `UserMgmtEnabled=0` is set.

**Root cause:** The correct section name for CODESYS 3.5.x+ is `[CmpUserMgmt]` (with a `t`). Using `[CmpUserMgr]` or `[UserMgmt]` is silently ignored — the section is unrecognized, user management stays enabled, and all login attempts fail silently.

**Fix:** Ensure `CODESYSControl_User.cfg` uses exactly:
```ini
[CmpUserMgmt]
UserMgmtEnabled=0
```

---

### Issue 6 — CODESYS IDE login fails with "operation not supported" (PKI conflict)

**Symptom:** First login attempt from a new CODESYS IDE project fails with "operation not supported" or similar cryptographic handshake error.

**Root cause:** Stale PKI certificates in `/var/opt/codesys/PKI/` from a previous runtime install conflict with the IDE's security context.

**Fix:**
```bash
systemctl stop codesyscontrol
rm -rf /var/opt/codesys/PKI/
systemctl start codesyscontrol
```
Also use a **fresh blank CODESYS project** — reusing an old project with cached device certificates causes the same error.

---

### Issue 7 — SysV init script conflicts with systemd (on `.deb` install)

**Symptom:** After installing the CODESYS `.deb`, `systemctl enable codesyscontrol.service` fails because `systemd-sysv-install` is not available on Yocto.

**Root cause:** The CODESYS `.deb` package installs `/etc/init.d/codesyscontrol` (a SysV init script). On Yocto with systemd-only, this script causes `systemctl enable` to attempt `systemd-sysv-install`, which is not present.

**Fix:** Remove the SysV script immediately after `.deb` install:
```bash
rm -f /etc/init.d/codesyscontrol
```
This is done automatically in `codesys-post-install.sh`.

---

### Issue 8 — `SchedulerInterval` default (4000 µs) causes RT latency spikes on CPU3

**Symptom:** cyclictest on CPU3 shows 200–400 µs worst-case latency even with RT kernel and CPU isolation correctly configured.

**Root cause:** The CODESYS `.deb` post-install resets `CODESYSControl.cfg` to defaults, including `SchedulerInterval=4000` (4 ms / 250 Hz). This is far too slow for tight RT and creates long idle periods where the RT core is unused then suddenly loaded.

**Fix:** Set `SchedulerInterval=500` (500 µs / 2 kHz) in `CODESYSControl.cfg`. The `codesys-setup.sh` always-overwrite mechanism ensures this survives IDE reinstalls.

---

### Issue 9 — `SysFileMap.cfg` approach does NOT load dynamic components

**Symptom:** Writing `CmpRetain=/opt/codesys/lib/libCmpRetain.so` into `/var/opt/codesys/SysFileMap.cfg` has no effect. The file is overwritten/regenerated by CODESYS on startup.

**Root cause:** `SysFileMap.cfg` is a CODESYS-managed file for static file path overrides, not for dynamic component registration. CODESYS regenerates it on startup. The correct mechanism for loading optional shared-library components is `[ComponentManager]` in the primary config.

**Fix:** See Issue 3. Use `[ComponentManager] Component.0=CmpRetain` in `CODESYSControl.cfg`.

---

### Issue 10 — `Logger.0.Path` key silently ignored

**Symptom:** Setting `Logger.0.Path=/run/codesys` in `CODESYSControl.cfg` does nothing. Log still appears in `/var/opt/codesys/`.

**Root cause:** CODESYS ignores the `Logger.0.Path` key. The log file always goes to the working directory (`/var/opt/codesys/`).

**Fix:** Use the symlink approach (Issue 2). Do not include `Logger.0.Path` in the config — it confuses future maintainers into thinking the path is configurable.

---

## Config File Reference Quick Map

```
/etc/codesys/                       ← Backup copies (authoritative source, owned by us)
    CODESYSControl.cfg              ← Copied to /etc/codesyscontrol/ on every boot
    CODESYSControl_User.cfg         ← Copied to /etc/codesyscontrol/ on every boot
    rt-override.conf                ← systemd drop-in (CPU3, SCHED_FIFO 80)

/etc/codesyscontrol/                ← Live config (read by CODESYS runtime)
    CODESYSControl.cfg
    CODESYSControl_User.cfg         ← Loaded via FileReference from main cfg
    SysFileMap.cfg                  ← CODESYS-managed, do not edit manually

/opt/codesys/
    bin/codesyscontrol              ← Runtime binary
    lib/                            ← Component shared libraries (.so)
    scripts/cfg_add_cmp.sh          ← CODESYS tool to add [ComponentManager] entries

/var/opt/codesys/
    codesyscontrol.log              ← Symlink → /run/codesys/codesyscontrol.log
    PlcLogic/                       ← PLC program storage
    cfg/                            ← Runtime-generated config state
    PKI/                            ← TLS certificates (delete to reset IDE trust)

/run/codesys/                       ← tmpfs (cleared on reboot)
    codesyscontrol.log              ← Actual log file (RAM, no SD writes)

/opt/codesys-packages/              ← Bundled install packages (from data/ at build time)
    codesyscontrol_linuxarm64_*.deb
    codesyscontrol_linuxarm64_*.ipk
```
