#!/bin/bash
# CODESYS pre-start setup script
# Called by codesyscontrol.service ExecStartPre=

set -euo pipefail

log() { echo "[$(date '+%Y-%m-%dT%H:%M:%S')] CODESYS-SETUP: $*"; }

# ── Check if binary is installed ─────────────────────────────────────────────
if [[ ! -x /opt/codesys/bin/codesyscontrol ]]; then
    log "CODESYS runtime binary not found at /opt/codesys/bin/codesyscontrol"
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
# /var/log is a symlink to /var/volatile/log on Yocto — must be created at runtime.
log "Preparing CODESYS directories"
mkdir -p /var/opt/codesys/PlcLogic
mkdir -p /var/opt/codesys/cfg
mkdir -p /run/codesys
chmod 755 /run/codesys
# Redirect CODESYS log to tmpfs — Logger.0.Path is ignored by the runtime;
# a symlink in its working dir is the only way to get log writes off the SD card.
ln -sf /run/codesys/codesyscontrol.log /var/opt/codesys/codesyscontrol.log 2>/dev/null || true


# ── Apply our RT config — always overwrite from /etc/codesys/ (authoritative) ─
# /etc/codesys/ is our backup; /etc/codesyscontrol/ is what the runtime reads.
# Always overwrite: the .deb post-install or IDE reinstall can silently replace
# /etc/codesyscontrol/CODESYSControl.cfg with defaults (SchedulerInterval=4000,
# Logger.0.Enable=1) which cause 200-400 µs RT latency spikes on CPU3.
mkdir -p /etc/codesyscontrol
cp /etc/codesys/CODESYSControl.cfg /etc/codesyscontrol/CODESYSControl.cfg
log "Applied CODESYSControl.cfg (SchedulerInterval=500, Logger disabled)"
cp /etc/codesys/CODESYSControl_User.cfg /etc/codesyscontrol/CODESYSControl_User.cfg
log "Applied CODESYSControl_User.cfg (UserMgmt disabled, RT settings)"

# ── Update shared library cache ───────────────────────────────────────────────
ldconfig

# ── Set resource limits ───────────────────────────────────────────────────────
ulimit -l unlimited  # memlock
ulimit -n 65536      # open files
ulimit -s 8192       # stack (KB)

log "CODESYS pre-start setup complete"
