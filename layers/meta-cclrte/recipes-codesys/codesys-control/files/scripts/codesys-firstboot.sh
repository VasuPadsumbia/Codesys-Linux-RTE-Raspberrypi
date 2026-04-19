#!/bin/bash
# codesys-firstboot.sh
# Author: Vasu Padsumbia
#
# Runs once on first boot to install CODESYS Control from bundled packages.
# Packages are baked into the image at /opt/codesys-packages/ by the Yocto build.
#
# Called by: codesys-firstboot.service (Type=oneshot)
# Stamp file: /var/lib/cclrte/codesys-installed (prevents re-run)

set -euo pipefail

STAMP="/var/lib/cclrte/codesys-installed"
PKG_DIR="/opt/codesys-packages"
LOG="/var/log/codesys/firstboot.log"

mkdir -p /var/lib/cclrte /var/log/codesys
log() { echo "[$(date '+%Y-%m-%dT%H:%M:%S')] CODESYS-FIRSTBOOT: $*" | tee -a "$LOG"; }

# Skip if already done
if [[ -f "$STAMP" ]]; then
    log "Already installed (stamp: $STAMP). Skipping."
    exit 0
fi

# Skip if runtime is already present (e.g. installed via CODESYS IDE)
if [[ -x /opt/codesys/bin/codesyscontrol ]]; then
    log "Runtime already at /opt/codesys/bin/codesyscontrol — marking installed."
    /usr/sbin/codesys-post-install.sh
    touch "$STAMP"
    exit 0
fi

# Locate bundled packages
DEB=$(find "$PKG_DIR" -name "*.deb" 2>/dev/null | sort | tail -1)
IPK=$(find "$PKG_DIR" -name "*.ipk" 2>/dev/null | sort | tail -1)

if [[ -z "$DEB" && -z "$IPK" ]]; then
    log "No packages found in $PKG_DIR"
    log "Install manually: /usr/sbin/install-codesys-runtime.sh /path/to/package.deb /path/to/package.ipk"
    exit 1
fi

log "Starting CODESYS runtime installation from bundled packages"
[[ -n "$DEB" ]] && log "  .deb: $DEB"
[[ -n "$IPK" ]] && log "  .ipk: $IPK"

# Install — .deb first (binary), then .ipk (component libraries + post-install data)
/usr/sbin/install-codesys-runtime.sh ${DEB:+"$DEB"} ${IPK:+"$IPK"}

# Mark as done
touch "$STAMP"
log "Installation complete. Stamp: $STAMP"
log "Connect CODESYS IDE to $(ip -4 addr show eth0 2>/dev/null | awk '/inet /{print $2}' | cut -d/ -f1 | head -1):1217"
