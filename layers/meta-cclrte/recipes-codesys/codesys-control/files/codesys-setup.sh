#!/bin/bash
# CODESYS pre-start setup script
# Called by codesyscontrol.service ExecStartPre=

set -euo pipefail

log() { echo "[$(date -Iseconds)] CODESYS-SETUP: $*"; }

# ── Check if binary is installed ─────────────────────────────────────────────
if [[ ! -x /opt/codesys/bin/codesyscontrol ]]; then
    log "CODESYS runtime binary not found at /opt/codesys/bin/codesyscontrol"
    log ""
    log "To install the CODESYS runtime:"
    log "  1. Obtain 'CODESYS Control for Linux SL' from https://store.codesys.com"
    log "  2. Transfer the package to this device (SCP via wlan0 management IP)"
    log "  3. Run: /usr/sbin/install-codesys-runtime.sh <path-to-package>"
    log ""
    log "The CODESYS service will not start until the runtime is installed."
    # Exit 0 — don't fail the boot process, just don't start
    exit 0
fi

# ── Prepare directories ───────────────────────────────────────────────────────
log "Preparing CODESYS directories"
install -d /var/opt/codesys/PlcLogic
install -d /var/opt/codesys/cfg
install -d /var/log/codesys
install -d /run/codesys

# ── Copy config if not already in runtime location ───────────────────────────
if [[ ! -f /var/opt/codesys/cfg/CODESYSControl.cfg ]]; then
    cp /etc/CODESYSControl.cfg /var/opt/codesys/cfg/
fi

# ── Update shared library cache ───────────────────────────────────────────────
ldconfig

# ── Set resource limits ───────────────────────────────────────────────────────
ulimit -l unlimited  # memlock
ulimit -n 65536      # open files
ulimit -s 8192       # stack (KB)

log "CODESYS pre-start setup complete"
