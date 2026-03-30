#!/bin/bash
# ============================================================================
# CODESYS Control for Linux SL — On-Target Runtime Installer
# ============================================================================
#
# OBTAINING THE PACKAGE:
#   1. Create a free account at https://store.codesys.com
#   2. Search for "CODESYS Control for Linux SL"
#   3. Download the ARM64 package (for Raspberry Pi 4 64-bit)
#   4. Transfer to this device:
#        scp CODESYSControl_*.deb root@<wlan0-ip>:/tmp/
#   5. Run this script:
#        /usr/sbin/install-codesys-runtime.sh /tmp/CODESYSControl_*.deb
#
# The CODESYS IDE (Windows) can then connect to:
#   eth0 IP: 192.168.1.100, Port: 1217
# ============================================================================

set -euo pipefail

INSTALL_DIR=/opt/codesys
LOG=/var/log/codesys/install.log

usage() {
    echo "Usage: $0 <path-to-CODESYSControl_*.deb>"
    echo ""
    echo "Obtain the package from: https://store.codesys.com"
    echo "  Product: CODESYS Control for Linux SL (ARM64 / Raspberry Pi)"
    exit 1
}

log() { echo "[$(date -Iseconds)] CODESYS-INSTALL: $*" | tee -a "$LOG"; }

[[ $# -lt 1 ]] && usage
PACKAGE_PATH="$1"
[[ ! -f "$PACKAGE_PATH" ]] && { echo "Error: file not found: $PACKAGE_PATH"; usage; }

mkdir -p "$(dirname "$LOG")"
log "Installing CODESYS Control runtime from: $PACKAGE_PATH"

# ── Detect package type ───────────────────────────────────────────────────────
if file "$PACKAGE_PATH" | grep -q "Debian"; then
    log "Package type: Debian (.deb)"
    EXTRACT_CMD="dpkg-deb --extract $PACKAGE_PATH $INSTALL_DIR"
elif file "$PACKAGE_PATH" | grep -q "gzip\|tar"; then
    log "Package type: tarball (.tar.gz)"
    EXTRACT_CMD="tar -xzf $PACKAGE_PATH -C $INSTALL_DIR --strip-components=1"
else
    log "ERROR: Unrecognised package format. Expected .deb or .tar.gz"
    exit 1
fi

# ── Extract ───────────────────────────────────────────────────────────────────
log "Extracting to $INSTALL_DIR ..."
mkdir -p "$INSTALL_DIR"
eval "$EXTRACT_CMD"

# ── Set permissions ───────────────────────────────────────────────────────────
find "$INSTALL_DIR/bin" -type f -exec chmod 0755 {} \; 2>/dev/null || true
find "$INSTALL_DIR/lib" -name "*.so*" -exec chmod 0755 {} \; 2>/dev/null || true

# ── Shared library cache ──────────────────────────────────────────────────────
echo "$INSTALL_DIR/lib" > /etc/ld.so.conf.d/codesys.conf
ldconfig
log "Shared library cache updated"

# ── Enable and start the service ─────────────────────────────────────────────
log "Enabling codesyscontrol service"
systemctl daemon-reload
systemctl enable codesyscontrol.service
systemctl start  codesyscontrol.service

log "============================================================"
log "CODESYS Control runtime installed successfully"
log ""
log "Connect the CODESYS IDE (Windows) to:"
log "  Programming port: 192.168.1.100:1217 (eth0)"
log "  WebUI:            http://<wlan0-ip>:8080"
log ""
log "First-time setup:"
log "  1. Open CODESYS IDE on Windows"
log "  2. Add gateway: Tools > Communication > Add gateway > 192.168.1.100"
log "  3. Scan devices — the RPi4 PLC should appear"
log "  4. Download your program and switch to Run mode"
log "============================================================"
