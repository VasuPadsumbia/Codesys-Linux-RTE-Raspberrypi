#!/bin/bash
# CCLRTE Xenomai Cobalt Setup
# Run this instead of rt-setup.sh when using the Xenomai build target.
# Cobalt manages RT scheduling on CPUs 2,3 directly — no chrt needed.

set -euo pipefail

log() { echo "[$(date -Iseconds)] CCLRTE-XENOMAI: $*"; }

log "Xenomai Cobalt setup starting"

# Verify Cobalt is running
if [[ -f /proc/xenomai/version ]]; then
    XENO_VER=$(cat /proc/xenomai/version)
    log "Xenomai Cobalt active: ${XENO_VER}"
else
    log "ERROR: Xenomai Cobalt not running — check kernel and module loading"
    exit 1
fi

# Load Xenomai RTnet for EtherCAT if available
if modprobe rtnet 2>/dev/null; then
    log "RTnet module loaded for EtherCAT"
fi

# Apply sysctl tuning (same as PREEMPT_RT — no RT bandwidth throttle)
sysctl -w kernel.sched_rt_runtime_us=-1 2>/dev/null || true
sysctl -w vm.swappiness=0

log "Xenomai Cobalt setup complete — CPUs 2,3 are in Cobalt domain"
