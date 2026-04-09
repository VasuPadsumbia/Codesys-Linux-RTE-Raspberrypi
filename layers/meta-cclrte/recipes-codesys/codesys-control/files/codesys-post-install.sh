#!/bin/bash
# codesys-post-install.sh
# Triggered automatically by codesys-ide-install.path when the CODESYS IDE
# deploys the runtime binary to /opt/codesys/bin/codesyscontrol via SSH.
#
# What this does:
#   1. Installs the RT drop-in override (persists IDE reinstalls)
#   2. Ensures CODESYSControl.cfg is present with RT settings
#   3. Ensures required directories exist
#   4. Reloads systemd and enables/starts codesyscontrol + codesysgateway
#   5. Applies SCHED_FIFO + CPU affinity directly to the running process

set -euo pipefail
log() { echo "[$(date -Iseconds)] CODESYS-POST-INSTALL: $*" | tee -a /var/log/codesys/post-install.log; }

log "CODESYS runtime detected at /opt/codesys/bin/codesyscontrol"
log "Applying RT configuration for PREEMPT_RT PLC environment"

# ── 1. RT drop-in override ─────────────────────────────────────────────────────
DROPIN_DIR=/etc/systemd/system/codesyscontrol.service.d
mkdir -p "$DROPIN_DIR"
if [[ ! -f "$DROPIN_DIR/rt-override.conf" ]]; then
    cp /etc/codesys/rt-override.conf "$DROPIN_DIR/rt-override.conf"
    log "Installed RT drop-in override: $DROPIN_DIR/rt-override.conf"
fi

# ── 2. Ensure CODESYSControl.cfg has RT settings ──────────────────────────────
if [[ ! -f /etc/CODESYSControl.cfg ]]; then
    log "CODESYSControl.cfg missing — restoring from /etc/codesys/"
    cp /etc/codesys/CODESYSControl.cfg /etc/CODESYSControl.cfg
fi

# ── 3. Runtime directories ────────────────────────────────────────────────────
mkdir -p /opt/codesys/lib
mkdir -p /var/opt/codesys/PlcLogic
mkdir -p /var/opt/codesys/cfg
mkdir -p /var/log/codesys
mkdir -p /run/codesys

# Shared library path for CODESYS runtime libs
if [[ ! -f /etc/ld.so.conf.d/codesys.conf ]]; then
    echo "/opt/codesys/lib" > /etc/ld.so.conf.d/codesys.conf
fi
ldconfig

# ── 4. Enable and start services ─────────────────────────────────────────────
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
