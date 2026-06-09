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

# ── 5. EtherCAT NIC (Waveshare RTL8111H, PCIe) — IRQ → CPU2 ─────────────────
# eth1 = Waveshare PCIe RTL8111H (net.ifnames=0, external PCIe FPC connector)
# eth0 = RPi5 internal NIC via RP1 (management / CODESYS programming port)
ETHERCAT_IF=${ETHERCAT_IF:-eth1}

# Auto-populate MASTER0_DEVICE in ethercat.conf if not already set.
# IgH uses MAC to identify which NIC to claim with ec_r8169.
ETHERCAT_CONF=/etc/ethercat.conf
if [[ -f "${ETHERCAT_CONF}" ]]; then
    CURRENT_MAC=$(grep -E '^MASTER0_DEVICE=' "${ETHERCAT_CONF}" | sed 's/MASTER0_DEVICE=//;s/"//g' | tr -d '[:space:]')
    if [[ -z "${CURRENT_MAC}" ]]; then
        NIC_MAC=$(cat "/sys/class/net/${ETHERCAT_IF}/address" 2>/dev/null || true)
        if [[ -n "${NIC_MAC}" ]]; then
            sed -i "s/^MASTER0_DEVICE=.*/MASTER0_DEVICE=\"${NIC_MAC}\"/" "${ETHERCAT_CONF}"
            log "EtherCAT MASTER0_DEVICE set to ${NIC_MAC} (${ETHERCAT_IF})"
        else
            log "WARNING: ${ETHERCAT_IF} not found — PCIe NIC not detected. Check dtparam=pciex1=on in config.txt"
        fi
    else
        log "EtherCAT MASTER0_DEVICE already set: ${CURRENT_MAC}"
    fi
fi

# Pin EtherCAT NIC IRQ to CPU2 before ec_r8169 loads.
# IRQ number persists across driver change (r8169 → ec_r8169).
ETH_IRQ=$(grep "${ETHERCAT_IF}" /proc/interrupts 2>/dev/null | awk -F: '{print $1}' | tr -d ' ' | head -n 1 || true)
if [[ -n "${ETH_IRQ}" ]]; then
    echo "4" > "/proc/irq/${ETH_IRQ}/smp_affinity" 2>/dev/null || true   # bitmask 0x4 = CPU2
    log "${ETHERCAT_IF} IRQ ${ETH_IRQ} pinned to CPU2"
    # MSI-X vectors for RTL8111H — pin all to CPU2
    for msix_irq_dir in "/proc/irq/"*/; do
        msix_irq=$(basename "${msix_irq_dir}")
        [[ "${msix_irq}" == "default_smp_affinity" ]] && continue
        if grep -q "${ETHERCAT_IF}" "${msix_irq_dir}/actions" 2>/dev/null; then
            echo "4" > "${msix_irq_dir}smp_affinity" 2>/dev/null || true
        fi
    done
else
    log "WARNING: ${ETHERCAT_IF} IRQ not found in /proc/interrupts"
fi

log "Xenomai Cobalt setup complete"
log "  PCIe NIC: ${ETHERCAT_IF} (RTL8111H) → IgH ec_r8169 → CPU2 SCHED_FIFO 90"
log "  EtherCAT: Cobalt hrtimer pipeline — hard-RT bus cycles"
log "  CODESYS:  Linux domain, PREEMPT_RT SCHED_FIFO 80, CPU3, target cycle 500 µs"
log "  Set CODESYS task cycle in IDE: Application > Task Configuration > T#500us"
