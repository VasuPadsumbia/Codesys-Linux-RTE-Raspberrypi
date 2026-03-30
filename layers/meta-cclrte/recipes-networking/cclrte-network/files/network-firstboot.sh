#!/bin/bash
# CCLRTE Network First-Boot Setup
# Reads /boot/site.conf (populated from config/site.conf.sample at build time)
# and writes live network configuration on first boot.
# Subsequent reboots skip this script (stamp file /var/lib/cclrte/network-configured).

set -euo pipefail

SITE_CONF=/boot/site.conf
STAMP=/var/lib/cclrte/network-configured
WPA_CONF=/etc/wpa_supplicant/wpa_supplicant-wlan0.conf
ETH0_NETWORK=/etc/systemd/network/10-eth0.network

log() { echo "[$(date -Iseconds)] CCLRTE-NETWORK: $*"; }

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

# ── WiFi credentials ──────────────────────────────────────────────────────────
WIFI_SSID=${WIFI_SSID:-""}
WIFI_PASSWORD=${WIFI_PASSWORD:-""}

if [[ -n "$WIFI_SSID" && -n "$WIFI_PASSWORD" ]]; then
    log "Configuring WiFi: $WIFI_SSID"
    WPA_BLOCK=$(wpa_passphrase "$WIFI_SSID" "$WIFI_PASSWORD")
    cat > "$WPA_CONF" <<EOF
ctrl_interface=DIR=/var/run/wpa_supplicant GROUP=netdev
update_config=1
country=${WIFI_COUNTRY:-DE}

${WPA_BLOCK}
EOF
    chmod 0600 "$WPA_CONF"
fi

# ── eth0 static IP ────────────────────────────────────────────────────────────
ETH0_IP=${ETH0_IP:-"192.168.1.100"}
ETH0_PREFIX=${ETH0_PREFIX:-"24"}
ETH0_GW=${ETH0_GW:-"192.168.1.1"}

log "Configuring eth0: ${ETH0_IP}/${ETH0_PREFIX} gw ${ETH0_GW}"
cat > "$ETH0_NETWORK" <<EOF
[Match]
Name=eth0

[Network]
Address=${ETH0_IP}/${ETH0_PREFIX}
Gateway=${ETH0_GW}
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
    cat > /etc/systemd/network/20-wlan0.network <<EOF
[Match]
Name=wlan0

[Network]
Address=${WLAN_IP}/${WLAN_PREFIX}
Gateway=${WLAN_GW}
DNS=8.8.8.8
Description=Management / WebUI / SSH
EOF
fi

# ── SSH authorized keys ────────────────────────────────────────────────────────
SSH_KEY=${SSH_AUTHORIZED_KEY:-""}
if [[ -n "$SSH_KEY" ]]; then
    log "Installing SSH authorized key for root"
    mkdir -p /root/.ssh
    chmod 0700 /root/.ssh
    echo "$SSH_KEY" >> /root/.ssh/authorized_keys
    chmod 0600 /root/.ssh/authorized_keys
fi

# ── Hostname ──────────────────────────────────────────────────────────────────
HOSTNAME=${DEVICE_HOSTNAME:-"cclrte-plc"}
log "Setting hostname: $HOSTNAME"
echo "$HOSTNAME" > /etc/hostname
hostname "$HOSTNAME"

# ── Stamp and restart networking ─────────────────────────────────────────────
touch "$STAMP"
log "Network configuration complete — restarting networkd"
systemctl daemon-reload
systemctl restart systemd-networkd || true
systemctl restart "wpa_supplicant@wlan0.service" || true

log "First-boot network setup done"
