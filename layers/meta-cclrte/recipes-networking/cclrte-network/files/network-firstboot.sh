#!/bin/bash
# CCLRTE Network First-Boot Setup
# Reads /boot/site.conf and writes live network configuration on first boot.
# Subsequent reboots skip this script (stamp file /var/lib/cclrte/network-configured).

# Do NOT use set -e here — individual steps use || true so partial failures are logged
# but don't abort the script before the stamp file is written.
set -uo pipefail

SITE_CONF=/boot/site.conf
STAMP=/var/lib/cclrte/network-configured
WPA_CONF=/etc/wpa_supplicant/wpa_supplicant-wlan0.conf
ETH0_NETWORK=/etc/systemd/network/10-eth0.network
# RPi5 built-in GbE: primary name eth0, altname end0.
ETH0_IFACE=eth0

log()  { echo "[$(date '+%Y-%m-%dT%H:%M:%S')] CCLRTE-NETWORK: $*"; }
warn() { echo "[$(date '+%Y-%m-%dT%H:%M:%S')] CCLRTE-NETWORK: WARNING: $*"; }

# Skip if already configured
[[ -f "$STAMP" ]] && { log "Network already configured, skipping"; exit 0; }

mkdir -p /var/lib/cclrte

# ── Read site.conf ────────────────────────────────────────────────────────────
if [[ -f "$SITE_CONF" ]]; then
    log "Reading site configuration from $SITE_CONF"
    # shellcheck source=/dev/null
    source "$SITE_CONF"
else
    log "No site.conf found at $SITE_CONF — using image defaults"
fi

# ── Write stamp early — prevents infinite retry if a later step fails ─────────
# All steps below use || true so failures are logged but non-fatal.
touch "$STAMP"
log "Stamp written — configuration proceeds (failures below are non-fatal)"

# ── WiFi credentials ──────────────────────────────────────────────────────────
WIFI_SSID=${WIFI_SSID:-""}
WIFI_PASSWORD=${WIFI_PASSWORD:-""}

# RPi5 soft-blocks WiFi by default — always unblock
if command -v rfkill >/dev/null 2>&1; then
    rfkill unblock wifi || true
    rfkill unblock all  || true
fi

if [[ -n "$WIFI_SSID" && -n "$WIFI_PASSWORD" ]]; then
    log "Configuring WiFi: $WIFI_SSID"
    if command -v wpa_passphrase >/dev/null 2>&1; then
        WPA_BLOCK=$(wpa_passphrase "$WIFI_SSID" "$WIFI_PASSWORD")
        cat > "$WPA_CONF" <<EOF
ctrl_interface=DIR=/var/run/wpa_supplicant
update_config=1
country=${WIFI_COUNTRY:-IN}
disable_scan_offload=1

${WPA_BLOCK}
EOF
        chmod 0600 "$WPA_CONF"
    else
        warn "wpa_passphrase not found — writing plain-text PSK"
        cat > "$WPA_CONF" <<EOF
ctrl_interface=DIR=/var/run/wpa_supplicant
update_config=1
country=${WIFI_COUNTRY:-IN}
disable_scan_offload=1

network={
    ssid="${WIFI_SSID}"
    psk="${WIFI_PASSWORD}"
    key_mgmt=WPA-PSK
}
EOF
        chmod 0600 "$WPA_CONF"
    fi
else
    log "No WIFI_SSID in site.conf — WiFi adapter unblocked but credentials not set"
fi

# ── eth0 static IP ────────────────────────────────────────────────────────────
ETH0_IP=${ETH0_IP:-"192.168.2.100"}
ETH0_PREFIX=${ETH0_PREFIX:-"24"}
ETH0_GW=${ETH0_GW:-"192.168.2.1"}

log "Configuring ${ETH0_IFACE}: ${ETH0_IP}/${ETH0_PREFIX} gw ${ETH0_GW}"
cat > "$ETH0_NETWORK" <<EOF || warn "Failed to write eth0 network config"
[Match]
Name=${ETH0_IFACE}

[Network]
Address=${ETH0_IP}/${ETH0_PREFIX}
Gateway=${ETH0_GW}
DNS=8.8.8.8
Description=CODESYS Programming Port

[Link]
WakeOnLan=off
EOF

# ── wlan0 static IP (optional) ────────────────────────────────────────────────
WLAN_IP=${WLAN_IP:-""}
if [[ -n "$WLAN_IP" ]]; then
    log "Configuring wlan0: ${WLAN_IP} (static)"
    WLAN_PREFIX=${WLAN_PREFIX:-"24"}
    WLAN_GW=${WLAN_GW:-"$(echo "$WLAN_IP" | cut -d. -f1-3).1"}
    cat > /etc/systemd/network/20-wlan0.network <<EOF || warn "Failed to write wlan0 static config"
[Match]
Name=wlan0

[Network]
Address=${WLAN_IP}/${WLAN_PREFIX}
Gateway=${WLAN_GW}
DNS=8.8.8.8
Description=Management / WebUI / SSH (Static)
EOF
else
    log "Configuring wlan0: DHCP"
    cat > /etc/systemd/network/20-wlan0.network <<EOF || warn "Failed to write wlan0 DHCP config"
[Match]
Name=wlan0

[Network]
DHCP=ipv4
Description=Management / WebUI / SSH (DHCP)

[DHCPv4]
RouteMetric=20
EOF
fi

# ── SSH authorized keys ────────────────────────────────────────────────────────
SSH_KEY=${SSH_AUTHORIZED_KEY:-""}
if [[ -n "$SSH_KEY" ]]; then
    log "Installing SSH authorized key for root"
    mkdir -p /root/.ssh || true
    chmod 0700 /root/.ssh || true
    echo "$SSH_KEY" >> /root/.ssh/authorized_keys || warn "Failed to write authorized_keys"
    chmod 0600 /root/.ssh/authorized_keys || true
fi

# ── Root password (optional override) ────────────────────────────────────────
DEVICE_PASSWORD=${DEVICE_PASSWORD:-""}
if [[ -n "$DEVICE_PASSWORD" ]]; then
    if command -v chpasswd >/dev/null 2>&1; then
        log "Setting root password from site.conf"
        echo "root:${DEVICE_PASSWORD}" | chpasswd || warn "chpasswd failed"
    else
        warn "chpasswd not found — root password not changed"
    fi
fi

# ── Hostname ──────────────────────────────────────────────────────────────────
HOSTNAME=${DEVICE_HOSTNAME:-"cclrte-plc"}
log "Setting hostname: $HOSTNAME"
echo "$HOSTNAME" > /etc/hostname || warn "Failed to write /etc/hostname"
hostname "$HOSTNAME" 2>/dev/null || hostnamectl set-hostname "$HOSTNAME" 2>/dev/null || warn "Failed to set running hostname"

# ── Restart networking (non-blocking — avoids hitting TimeoutStartSec) ───────
log "Network configuration complete — signalling networkd to reload"
systemctl daemon-reload || true
# --no-block: fire-and-forget; networkd/wpa_supplicant start independently
systemctl restart --no-block systemd-networkd || true
systemctl restart --no-block "wpa_supplicant@wlan0.service" || true

log "First-boot network setup done"
