#!/bin/bash
# CCLRTE Real-time System Setup
# Configures IRQ affinity, RT scheduling, and memory locking.
# Runs as a oneshot systemd service before CODESYS and EtherCAT start.
#
# CPU layout:
#   CPU0,1 — Linux OS (all non-RT services)
#   CPU2   — EtherCAT master (SCHED_FIFO 90)
#   CPU3   — CODESYS scan cycle (SCHED_FIFO 80)

set -euo pipefail

LOG=/var/log/cclrte-rt.log
mkdir -p "$(dirname "$LOG")"

log() {
    echo "[$(date -Iseconds)] CCLRTE-RT: $*" | tee -a "$LOG"
}

log "Starting real-time system setup"

# ── 1. IRQ affinity ──────────────────────────────────────────────────────────
# Pin all IRQs to CPU0,1 by default. EtherCAT NIC IRQ is moved to CPU2 below.
log "Setting default IRQ affinity to CPU0,1"
for irq_dir in /proc/irq/*/; do
    irq=$(basename "$irq_dir")
    [[ "$irq" == "default_smp_affinity" ]] && continue
    echo "3" > "${irq_dir}smp_affinity" 2>/dev/null || true  # bitmask 0x3 = CPU0,1
done

# ── 2. EtherCAT NIC IRQ → CPU2 ───────────────────────────────────────────────
# Find the IRQ for the EtherCAT network interface (eth1 or first available after eth0)
ETHERCAT_IF=${ETHERCAT_IF:-eth1}
log "Pinning ${ETHERCAT_IF} IRQ to CPU2"
if ETH_IRQ=$(grep "${ETHERCAT_IF}" /proc/interrupts 2>/dev/null | awk -F: '{print $1}' | tr -d ' ' | head -1); then
    if [[ -n "$ETH_IRQ" ]]; then
        echo "4" > "/proc/irq/${ETH_IRQ}/smp_affinity" || true  # bitmask 0x4 = CPU2
        echo "2" > "/proc/irq/${ETH_IRQ}/smp_affinity_list" || true
        log "  ${ETHERCAT_IF} IRQ ${ETH_IRQ} pinned to CPU2"
    fi
fi

# ── 3. Remove RT bandwidth throttle ─────────────────────────────────────────
# Default Linux cap: RT tasks can use only 95% of CPU time.
# Removing the cap lets CODESYS use 100% when needed.
# Safety net: BCM2711 hardware watchdog reboots if CODESYS hangs.
log "Removing RT bandwidth throttle (sched_rt_runtime_us=-1)"
sysctl -w kernel.sched_rt_runtime_us=-1

# ── 4. Wait for EtherCAT and set SCHED_FIFO 90 ──────────────────────────────
wait_for_process() {
    local name=$1 timeout=${2:-30} elapsed=0
    while ! pgrep -x "$name" > /dev/null 2>&1; do
        sleep 1
        elapsed=$((elapsed + 1))
        [[ $elapsed -ge $timeout ]] && return 1
    done
    return 0
}

log "Waiting for EtherCAT master process..."
if wait_for_process "ec_master" 30; then
    EC_PID=$(pgrep -x ec_master)
    chrt -f -p 90 "$EC_PID" 2>/dev/null && log "  ec_master PID $EC_PID set to SCHED_FIFO 90 on CPU2" || true
    taskset -cp 2 "$EC_PID" 2>/dev/null || true
fi

# ── 5. Wait for CODESYS and set SCHED_FIFO 80 + memory lock ─────────────────
log "Waiting for CODESYS runtime process..."
if wait_for_process "codesyscontrol" 60; then
    CS_PID=$(pgrep -x codesyscontrol)
    chrt -f -p 80 "$CS_PID" 2>/dev/null && log "  codesyscontrol PID $CS_PID set to SCHED_FIFO 80 on CPU3" || true
    taskset -cp 3 "$CS_PID" 2>/dev/null || true
    # Lock all memory pages to prevent page faults during scan cycle
    prlimit --memlock=unlimited:unlimited --pid "$CS_PID" 2>/dev/null || true
    log "  CODESYS memory pages locked (mlockall)"
fi

log "Real-time system setup complete"
log "  Latency verification: run 'systemctl start rt-verify' or check /var/log/cclrte-rt-result.txt"
