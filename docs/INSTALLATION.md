# Installation Guide
<!-- Author: Vasu Padsumbia -->

This guide walks through building the cclrte image, flashing it to an SD card, and deploying CODESYS Control for Linux SL on a Raspberry Pi 5.

---

## Hardware Requirements

### Required

| Component | Specification |
|-----------|---------------|
| **SBC** | Raspberry Pi 5 **2 GB RAM** (tested and validated) |
| **SD card** | 16 GB minimum, **Class 10 / UHS-I** or better; industrial-grade recommended for production |
| **Power supply** | **5 V 5 A USB-C** — use the official RPi5 PSU; inadequate power causes RT latency spikes and thermal throttling |
| **Cooling** | **Active cooling required** — heatsink + fan; `force_turbo=1` locks CPU at 2.4 GHz continuously |
| **EtherCAT NIC** | USB-to-Ethernet adapter (RTL8152 or AX88179 chipset) for eth1; must be dedicated to fieldbus (no IP assigned) |
| **Ethernet cable** | For eth0 (192.168.2.100 static) — connects to CODESYS programming PC |
| **WiFi** | Built-in RPi5 WiFi (CYW43455); for management/WebUI access |

### Optional (by protocol)

| Component | Protocol | Notes |
|-----------|----------|-------|
| IO-Link HAT (SPI0) | IO-Link | iol (rt-labs) driver, 4 ports; HAT must be iol-compatible |
| MCP2515 HAT (SPI) | CAN / CANopen | Configure via CODESYS CANopen master SL |
| RS-485 HAT (UART0) | Modbus RTU | Connected to `/dev/ttyAMA0` (PL011 freed from BT by `dtoverlay=disable-bt`) |
| Additional Ethernet NIC | PROFINET | For CODESYS PROFINET SL add-on (controller role) |

### RPi5 GPIO Pin Usage

| Interface | Pins | Use |
|-----------|------|-----|
| SPI0 | GPIO 8–11 | IO-Link HAT |
| SPI1 | GPIO 16–21 | CAN HAT (MCP2515) |
| UART0 (ttyAMA0) | GPIO 14, 15 | RS-485 / Modbus |
| I2C1 | GPIO 2, 3 | Sensor / HMI expansion |

---

## Host Build System Requirements

Build has been validated on **Ubuntu 22.04 LTS** and **Ubuntu 24.04 LTS**.

### Packages

```bash
sudo apt update
sudo apt install -y \
    git wget curl file \
    gcc g++ make diffstat texinfo chrpath socat \
    libsdl1.2-dev xterm cpio lz4 \
    python3 python3-pip python3-venv \
    zstd lz4 pv
```

### Resources

| Resource | Minimum | Recommended |
|----------|---------|-------------|
| RAM | 8 GB | 16 GB |
| CPU cores | 4 | 8+ |
| Disk (build) | 80 GB | 150 GB |
| Disk (downloads) | 20 GB | 40 GB |
| Internet | Required for first build | — |

> **Tip:** Set `DL_DIR` and `SSTATE_DIR` to a fast SSD. The default location is one directory above the build dir (`../downloads`, `../sstate-cache`), shared across all build targets.

---

## Step-by-Step Build

### Step 1: Clone the Repository

```bash
git clone https://github.com/yourusername/yocto-gateway-rt.git
cd yocto-gateway-rt
```

### Step 2: Configure Site Settings

```bash
cp config/site.conf.sample config/site.conf
nano config/site.conf
```

Edit the following fields:

```bash
# Root password — default is "cclrte", set here to change on first boot
DEVICE_PASSWORD=""

# WiFi for management interface (wlan0)
WIFI_SSID="MyNetwork"
WIFI_PASSWORD="MyPassword"
WIFI_COUNTRY="IN"          # ISO 3166-1 alpha-2 country code for your region

# SSH key for root access (paste your public key for passwordless login)
SSH_AUTHORIZED_KEY="ssh-ed25519 AAAA... user@host"

# eth0 — CODESYS programming port (static)
ETH0_IP="192.168.2.100"
ETH0_PREFIX="24"
ETH0_GW="192.168.2.1"

# wlan0 IP — leave empty for DHCP (recommended)
WLAN_IP=""

# Hostname
DEVICE_HOSTNAME="cclrte-plc"
```

> **Security:** `config/site.conf` is in `.gitignore` and must never be committed — it contains WiFi passwords and SSH keys.

### Step 3: Set Up Python Virtual Environment

The first `./cclrte.sh` invocation creates the venv automatically, or run manually:

```bash
python3 -m venv venv
source venv/bin/activate
pip install -r requirements.txt
```

### Step 4: Place CODESYS Runtime Packages in `data/`

CODESYS Control for Linux SL is a closed-license commercial product. The runtime packages are **not included in the git repository** but must be placed in `data/` before building.

```bash
# Obtain from CODESYS IDE → Help → Install CODESYS Control for Linux
# OR from https://store.codesys.com (CODESYS Control for Linux SL → Downloads)
#
# Place BOTH files in data/:
ls data/
# codesyscontrol_linuxarm64_4.20.0.0_arm64.deb   ← runtime binary
# codesyscontrol_linuxarm64_4.20.0.0_arm64.ipk   ← component libraries
```

> The build will fail with a clear error message if either file is missing.

These packages are bundled into the image at `/opt/codesys-packages/` and installed automatically on first boot via `codesys-firstboot.service` — no manual installation step required.

### Step 5 (Xenomai only): Obtain Dovetail Kernel Patches

The Xenomai build requires Dovetail interrupt pipeline patches applied to the RPi5 kernel (6.6.y). This is a community effort and must be done manually:

```bash
# Obtain Dovetail patches for kernel 6.6 / BCM2712 / arm64
# Source: https://source.denx.de/Xenomai/linux-dovetail (v6.6.y/dovetail branch)

# Place .patch files in:
mkdir -p layers/meta-cclrte/recipes-kernel/linux-xenomai/files/patches/
# Then uncomment SRC_URI patch lines in linux-raspberrypi-xenomai_6.6.bb
```

> **Note:** Dovetail patch availability for BCM2712 (RPi5) must be verified against the kernel version in scarthgap. Check the Xenomai mailing list for current status.

### Step 5: Build the Image

**PREEMPT_RT build (recommended first)**

```bash
./cclrte.sh build preempt-rt
# Equivalent: kas build kas/rpi5-64.yml
```

**Xenomai Cobalt build** (after completing Step 4)

```bash
./cclrte.sh build xenomai
# Equivalent: kas build kas/rpi5-xenomai.yml
```

**QEMU CI build** (no RPi hardware required)

```bash
./cclrte.sh build qemu
# Equivalent: kas build kas/qemu-x86-64.yml
```

Build times (first build, 8-core host):
- PREEMPT_RT: ~5–7 hours
- Xenomai: ~6–8 hours
- QEMU: ~3–5 hours

Subsequent builds with warm sstate-cache: ~10–30 minutes.

After editing recipes in `layers/meta-cclrte/`, use targeted clean instead of full rebuild:

```bash
./cclrte.sh clean recipes preempt-rt   # invalidate only meta-cclrte sstate
./cclrte.sh build preempt-rt           # rebuild (upstream cache preserved)
```

### Step 6: Flash the SD Card

Identify your SD card device (**not `/dev/sda`** — that is usually your boot disk):

```bash
lsblk
# Look for your SD card, e.g. /dev/sdb or /dev/mmcblk0
```

Flash:

```bash
# PREEMPT_RT build
./cclrte.sh load /dev/sdb preempt-rt

# Xenomai build
./cclrte.sh load /dev/sdb xenomai
```

The script will:
1. Refuse to write to `/dev/sda` without `--force` (safety guard)
2. Use `pv` for progress if available
3. Write the image with `dd`, then **automatically copy `config/site.conf` to the boot partition**

> **Eject safely:** `sync && sudo eject /dev/sdb`

### Step 7: First Boot

Insert the SD card into the RPi5 and power on.

On first boot, `network-firstboot.sh` runs once and:
1. Reads `/boot/site.conf` (copied automatically by `./cclrte.sh load`)
2. Configures eth0 static address (default: 192.168.2.100/24)
3. Configures wlan0 with WiFi credentials
4. Installs SSH authorized key for root
5. Sets hostname
6. Creates stamp file `/var/lib/cclrte/network-configured` (prevents re-run)

Wait ~60 seconds, then connect:

```bash
# Via Ethernet — set your PC to 192.168.2.x/24
ssh root@192.168.2.100
# Default password: cclrte

# Via WiFi — check router DHCP table for wlan0 IP
ssh root@<wlan0-ip>
```

### Step 8: Verify RT Setup

```bash
# On the RPi5
systemctl status rt-setup.service
cat /var/log/cclrte-rt-result.txt  # cyclictest result (from WebUI or manual run)
```

Or trigger via the **WebUI → System → Run cyclictest (~3 min)** button.

A passing result:

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

`worst_max_us` is the worst of CPU2 and CPU3 only (isolated RT cores). The SMP baseline (`smp_max_us`) is excluded — OS cores 0 and 1 are expected to have higher jitter and are not the pass/fail gate.

If `worst_max_us` >= 100, consider the Xenomai build.

### Step 9: CODESYS Runtime (Auto-installed on First Boot)

If you placed the packages in `data/` before building (Step 4), CODESYS is **automatically installed on first boot** — no manual action required.

`codesys-firstboot.service` runs once and:
1. Extracts and installs the `.deb` (runtime binary → `/opt/codesys/bin/codesyscontrol`)
2. Installs the `.ipk` via opkg (component libraries + post-install scripts)
3. Applies RT tuning (CPU3, SCHED_FIFO 80, `mlockall`)
4. Enables and starts `codesyscontrol.service`
5. Creates stamp `/var/lib/cclrte/codesys-installed`

Monitor installation:
```bash
journalctl -u codesys-firstboot -f
# After completion:
cat /var/log/codesys/firstboot.log
```

**Verify:**
```bash
systemctl status codesyscontrol
ss -tlnp | grep 1217   # Gateway port (IDE connects here)
```

**Manual reinstall** (if firstboot failed or packages were updated):
```bash
rm /var/lib/cclrte/codesys-installed
systemctl start codesys-firstboot
# OR: copy new packages and run directly:
/usr/sbin/install-codesys-runtime.sh /opt/codesys-packages/*.deb /opt/codesys-packages/*.ipk
```

### Step 10: Connect CODESYS IDE

Verify the runtime is listening before connecting:

```bash
ss -tlnp | grep 1217   # must show LISTEN
```

In CODESYS Development System on your programming PC:

1. **Online → Scan Network** — the `cclrte-plc` device appears automatically
2. Double-click the device → click **Login** (leave username/password blank — User Management is disabled)
3. **Online → Download** your PLC project

> **No login required:** `UserMgmtEnabled=0` is set in the device config. The IDE connects without credentials. Enable device User Management via CODESYS Security Screen for production deployments.

> **Network:** Connect your programming PC to eth0 (set PC IP to 192.168.2.x/24, no gateway needed).

---

## WebUI Access

```
http://192.168.2.100:8080    (via Ethernet)
http://<wlan0-ip>:8080       (via WiFi)
```

Default credentials (change immediately after first login):
- Username: `admin`
- Password: `admin`

The WebUI provides:
- Service status monitoring and control
- RT latency results and on-demand cyclictest
- Network reconfiguration (eth0, wlan0, SSH keys)
- CODESYS log viewer
- Password change and system reboot

---

## Troubleshooting

| Problem | Solution |
|---------|----------|
| No wlan0 connection | Check `WIFI_SSID`/`WIFI_PASSWORD` and `WIFI_COUNTRY` in `config/site.conf`; `journalctl -u wpa_supplicant@wlan0` |
| eth0 not at 192.168.2.100 | Run `networkctl status eth0`; check `/etc/systemd/network/10-eth0.network` |
| network-firstboot did not run | Check `journalctl -u network-firstboot`; verify `/boot/site.conf` exists |
| codesyscontrol not starting | Check `ls /opt/codesys/bin/codesyscontrol` — if missing, run `install-codesys-runtime.sh`; then `journalctl -u codesyscontrol -e` |
| codesys-firstboot failed | `journalctl -u codesys-firstboot`; check `/var/log/codesys/firstboot.log`; re-run: `rm /var/lib/cclrte/codesys-installed && systemctl start codesys-firstboot` |
| IDE scan finds no PLC | Verify `ss -tlnp \| grep 1217` shows LISTEN; check `systemctl status codesyscontrol` |
| IDE login fails silently | Verify `/etc/codesyscontrol/CODESYSControl_User.cfg` has `[CmpUserMgmt]` (not `[CmpUserMgr]`) with `UserMgmtEnabled=0` |
| IDE login fails "operation not supported" | Wipe PKI: `systemctl stop codesyscontrol && rm -rf /var/opt/codesys/PKI/ && systemctl start codesyscontrol`; use a new blank project |
| RT latency on CPU3 > 100 µs | Verify `SchedulerInterval=500` in `CODESYSControl.cfg`; verify `Logger.0.Enable=0`; consider Xenomai build |
| High RT latency (> 100 µs) | Verify `scaling_governor` = `performance`; check USB device interrupts; consider Xenomai build |
| EtherCAT in ACTIVATING state | Set MAC address of USB-NIC via WebUI Protocols page or: `echo 'MASTER0_DEVICE="aa:bb:cc:dd:ee:ff"' > /etc/ethercat.conf` |
| Build fails with layer error | Verify kas version >= 4.0; check Xenomai: Dovetail patches placed correctly |
| SD card write fails | Verify you are NOT writing to `/dev/sda`; use `--force` only if absolutely certain |
| WebUI login loop | Delete `/var/lib/cclrte/webui-credentials.json`; restart `plc-webui` |
| plc-webui service fails | Check `/usr/bin/python3` exists; `journalctl -u plc-webui -e` |
