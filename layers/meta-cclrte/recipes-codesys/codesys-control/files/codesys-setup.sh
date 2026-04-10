#!/bin/bash
# CODESYS pre-start setup script
# Called by codesyscontrol.service ExecStartPre=

set -euo pipefail

log() { echo "[$(date '+%Y-%m-%dT%H:%M:%S')] CODESYS-SETUP: $*"; }

# ── Check if binary is installed ─────────────────────────────────────────────
if [[ ! -x /opt/codesys/bin/codesyscontrol.bin ]]; then
    log "CODESYS runtime binary not found at /opt/codesys/bin/codesyscontrol.bin"
    log ""
    log "To install the CODESYS runtime:"
    log "  1. Obtain 'CODESYS Control for Linux SL' from https://store.codesys.com"
    log "  2. SCP the .deb to this device: scp *.deb root@192.168.2.100:/tmp/"
    log "  3. Run: /usr/sbin/install-codesys-runtime.sh /tmp/<package>.deb"
    log ""
    log "The CODESYS service will not start until the runtime is installed."
    # Exit 0 — don't fail the boot process, just don't start
    exit 0
fi

# ── Prepare directories ───────────────────────────────────────────────────────
log "Preparing CODESYS directories"
mkdir -p /var/opt/codesys/PlcLogic
mkdir -p /var/opt/codesys/cfg
mkdir -p /var/log/codesys
mkdir -p /run/codesys

# ── Ensure config exists at the path codesyscontrol.bin reads ────────────────
# .bin reads /etc/codesyscontrol/CODESYSControl.cfg (set in ExecStart)
# Restore from our backup if the .deb install overwrote it with defaults.
if [[ ! -f /etc/codesyscontrol/CODESYSControl.cfg ]]; then
    mkdir -p /etc/codesyscontrol
    cp /etc/codesys/CODESYSControl.cfg /etc/codesyscontrol/CODESYSControl.cfg
    log "Restored CODESYSControl.cfg to /etc/codesyscontrol/"
fi

# ── Update shared library cache ───────────────────────────────────────────────
ldconfig

# ── Set resource limits ───────────────────────────────────────────────────────
ulimit -l unlimited  # memlock
ulimit -n 65536      # open files
ulimit -s 8192       # stack (KB)

log "CODESYS pre-start setup complete"
