#!/bin/bash
# codesys-post-install.sh — CODESYS RT configuration and service startup
# Author: Vasu Padsumbia
#
# Run this after CODESYS Control for Linux SL is installed (by any method).
# Safe to run multiple times — all operations are idempotent.
#
# USAGE:
#   /usr/sbin/codesys-post-install.sh
#
# CALLED BY:
#   - install-codesys-runtime.sh  (manual install via SSH)
#   - codesys-ide-install.service (automatically when CODESYS IDE deploys via SSH)
#
# WHAT THIS DOES:
#   1. Installs the RT drop-in override (CPU3, SCHED_FIFO 80) — persists IDE reinstalls
#   2. Ensures CODESYSControl.cfg + User.cfg (UserMgmt disabled) are in place
#   3. Ensures required runtime directories exist
#   4. Removes SysV init.d script that conflicts with our systemd unit
#   5. Reloads systemd and enables/starts codesyscontrol + codesysgateway
#   6. Applies SCHED_FIFO 80 + CPU3 affinity to the running process directly

set -euo pipefail
mkdir -p /var/log/codesys
log() { echo "[$(date '+%Y-%m-%dT%H:%M:%S')] CODESYS-POST-INSTALL: $*" | tee -a /var/log/codesys/post-install.log; }

log "CODESYS runtime detected — applying RT configuration"
log "Applying RT configuration for PREEMPT_RT PLC environment"

# ── 1. RT drop-in override ─────────────────────────────────────────────────────
DROPIN_DIR=/etc/systemd/system/codesyscontrol.service.d
mkdir -p "$DROPIN_DIR"
if [[ ! -f "$DROPIN_DIR/rt-override.conf" ]]; then
    cp /etc/codesys/rt-override.conf "$DROPIN_DIR/rt-override.conf"
    log "Installed RT drop-in override: $DROPIN_DIR/rt-override.conf"
fi

# ── 2. Ensure CODESYSControl_User.cfg has our RT + gateway settings ──────────
# The IDE wizard regenerates CODESYSControl.cfg but does NOT touch the User cfg.
# We always (re)write the User cfg so gateway and RT settings survive reinstalls.
mkdir -p /etc/codesyscontrol
cp /etc/codesys/CODESYSControl_User.cfg /etc/codesyscontrol/CODESYSControl_User.cfg
log "Applied RT + gateway settings to CODESYSControl_User.cfg"

# If the main config doesn't reference the User file, add the reference.
# (The wizard always includes it in its generated config, so this is a safety net.)
if ! grep -q "CODESYSControl_User.cfg" /etc/codesyscontrol/CODESYSControl.cfg 2>/dev/null; then
    echo "" >> /etc/codesyscontrol/CODESYSControl.cfg
    echo "[CmpSettings]" >> /etc/codesyscontrol/CODESYSControl.cfg
    echo "FileReference.1=/etc/codesyscontrol/CODESYSControl_User.cfg" >> \
        /etc/codesyscontrol/CODESYSControl.cfg
    log "Added FileReference to CODESYSControl.cfg → CODESYSControl_User.cfg"
fi

# ── 3. Runtime directories ────────────────────────────────────────────────────
mkdir -p /opt/codesys/lib
mkdir -p /var/opt/codesys/PlcLogic
mkdir -p /var/opt/codesys/cfg
mkdir -p /run/codesys

# ── CmpRetain — register dynamic component via ComponentManager ───────────────
# CmpRetain (retain variable persistence) is a dynamic shared lib not
# auto-discovered by CODESYS. cfg_add_cmp.sh adds it to [ComponentManager]
# in the User.cfg — same mechanism the .ipk post-install uses.
if [[ -f /opt/codesys/lib/libCmpRetain.so && -f /opt/codesys/scripts/cfg_add_cmp.sh ]]; then
    /opt/codesys/scripts/cfg_add_cmp.sh \
        /etc/codesyscontrol/CODESYSControl_User.cfg CmpRetain
    log "Registered CmpRetain in [ComponentManager]"
fi

# Shared library path for CODESYS runtime libs
if [[ ! -f /etc/ld.so.conf.d/codesys.conf ]]; then
    echo "/opt/codesys/lib" > /etc/ld.so.conf.d/codesys.conf
fi
ldconfig

# ── 4. Remove SysV init script — the .deb installs /etc/init.d/codesyscontrol
# which causes systemctl enable to look for systemd-sysv-install (not on Yocto).
# Our systemd service unit handles everything — the init.d script is not needed.
if [[ -f /etc/init.d/codesyscontrol ]]; then
    rm /etc/init.d/codesyscontrol
    log "Removed /etc/init.d/codesyscontrol (SysV script conflicts with systemd unit)"
fi

# ── 5. Enable and start services ─────────────────────────────────────────────
log "Reloading systemd daemon"
systemctl daemon-reload

log "Enabling codesyscontrol.service"
systemctl enable codesyscontrol.service

# Start gateway first if binary present
if [[ -x /opt/codesys/gateway/codesysgateway ]]; then
    log "Starting CODESYS Gateway"
    systemctl enable codesysgateway.service
    systemctl start codesysgateway.service || log "Gateway start failed — check journalctl -u codesysgateway"
fi

log "Starting CODESYS Control runtime"
systemctl start codesyscontrol.service || log "Runtime start failed — check journalctl -u codesyscontrol"

# ── 5. Apply RT scheduling to running process ─────────────────────────────────
# systemd CPUAffinity/CPUSchedulingPolicy apply at start, but enforce here too
# in case process forks and systemd loses track
sleep 2
PID=$(pgrep -x codesyscontrol 2>/dev/null || true)
if [[ -n "$PID" ]]; then
    log "Applying SCHED_FIFO 80 + CPU3 affinity to PID $PID"
    chrt -f -p 80 "$PID"    2>/dev/null || true
    taskset -cp 3 "$PID"    2>/dev/null || true
    # Lock all memory pages — no page faults during scan cycle
    prlimit --memlock=unlimited:unlimited --pid "$PID" 2>/dev/null || true
    log "RT settings applied to CODESYS process PID=$PID"
else
    log "CODESYS process not yet running — RT settings will apply via service unit"
fi

log "CODESYS runtime ready. Connect CODESYS IDE to $(ip -4 addr show eth0 | awk '/inet /{print $2}' | cut -d/ -f1):1217"
