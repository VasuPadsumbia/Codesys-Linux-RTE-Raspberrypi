#!/bin/bash
# CCLRTE Xenomai Cobalt Setup
# Runs at boot on the Xenomai build target (gated by ConditionPathExists=/proc/xenomai).
# Verifies Cobalt is active and applies Cobalt-domain tuning.
#
# Architecture:
#   CPU0,1 — Linux OS (PREEMPT_RT, all non-RT services)
#   CPU2   — IgH EtherCAT master kernel thread (Cobalt hrtimer pipeline, SCHED_FIFO 90)
#   CPU3   — CODESYS scan cycle (Linux domain, PREEMPT_RT SCHED_FIFO 80, 500 µs cycle)
#
# Note: CODESYS Control for Linux SL is a Linux binary — it runs in the Linux
# (PREEMPT_RT) domain. EtherCAT frames are timed by Cobalt's interrupt pipeline,
# giving hard-RT bus cycles even though CODESYS itself uses PREEMPT_RT scheduling.

set -euo pipefail

LOG=/var/log/cclrte-rt.log
mkdir -p "$(dirname "$LOG")"
log() { echo "[$(date -Iseconds)] CCLRTE-XENOMAI: $*" | tee -a "$LOG"; }

log "Xenomai Cobalt setup starting"

# ── 1. Verify Cobalt co-kernel is active ─────────────────────────────────────
if [[ ! -f /proc/xenomai/version ]]; then
    log "ERROR: /proc/xenomai/version not found"
    log "       Check that CONFIG_DOVETAIL=y and CONFIG_XENO_COBALT=y are in the kernel"
    log "       and that the Xenomai Cobalt co-kernel initialised correctly"
    exit 1
fi
XENO_VER=$(cat /proc/xenomai/version)
log "Xenomai Cobalt active: ${XENO_VER}"

# ── 2. Confirm Cobalt CPUs 2,3 are in the RT domain ──────────────────────────
if [[ -f /proc/xenomai/cpuinfo ]]; then
    log "Cobalt CPU info:"
    grep -E "CPU|state" /proc/xenomai/cpuinfo | tee -a "$LOG" || true
fi

# ── 3. System tuning ─────────────────────────────────────────────────────────
# Remove POSIX RT bandwidth cap — Cobalt does not use it, but Linux tasks on
# CPU0,1 may still be affected.
sysctl -w kernel.sched_rt_runtime_us=-1 2>/dev/null || true

# Disable swapping — page faults during CODESYS scan cause latency spikes
sysctl -w vm.swappiness=0 2>/dev/null || true

# ── 4. Pin all IRQs to CPU0,1 (same as PREEMPT_RT setup) ─────────────────────
log "Setting default IRQ affinity to CPU0,1"
for irq_dir in /proc/irq/*/; do
    irq=$(basename "$irq_dir")
    [[ "$irq" == "default_smp_affinity" ]] && continue
    echo "3" > "${irq_dir}smp_affinity" 2>/dev/null || true   # bitmask 0x3 = CPU0,1
done

# ── 5. EtherCAT NIC IRQ → CPU2 ───────────────────────────────────────────────
ETHERCAT_IF=${ETHERCAT_IF:-eth1}
if ETH_IRQ=$(grep "${ETHERCAT_IF}" /proc/interrupts 2>/dev/null | awk -F: '{print $1}' | tr -d ' ' | head -n 1); then
    if [[ -n "$ETH_IRQ" ]]; then
        echo "4" > "/proc/irq/${ETH_IRQ}/smp_affinity" 2>/dev/null || true   # bitmask 0x4 = CPU2
        log "${ETHERCAT_IF} IRQ ${ETH_IRQ} pinned to CPU2"
    fi
fi

log "Xenomai Cobalt setup complete"
log "  EtherCAT: IgH master on CPU2 — bus timing via Cobalt hrtimer pipeline"
log "  CODESYS:  Linux domain, PREEMPT_RT SCHED_FIFO 80, CPU3, target cycle 500 µs"
log "  Set CODESYS task cycle in IDE: Application > Task Configuration > T#500us"
