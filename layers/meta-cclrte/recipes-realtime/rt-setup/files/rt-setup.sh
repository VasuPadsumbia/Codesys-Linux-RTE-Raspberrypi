#!/bin/bash
# CCLRTE Real-time System Setup (PREEMPT_RT)
# Runs as a oneshot systemd service BEFORE EtherCAT and CODESYS start.
# Handles: IRQ affinity, sysctl tuning, memory settings.
#
# CPU layout:
#   CPU0,1 — Linux OS (all non-RT services, WebUI, SSH, MQTT, OPC-UA)
#   CPU2   — IgH EtherCAT master (SCHED_FIFO 90) — set by ethercat.service unit
#   CPU3   — CODESYS scan cycle (SCHED_FIFO 80)  — set by rt-override.conf drop-in
#
# NOTE: SCHED_FIFO and CPUAffinity for EtherCAT and CODESYS are applied by
# their respective systemd unit files (ethercat.service, rt-override.conf).
# This script handles system-wide settings that must be in place before they start.

set -euo pipefail

LOG=/var/log/cclrte-rt.log
mkdir -p "$(dirname "$LOG")"

log() {
    echo "[$(date '+%Y-%m-%dT%H:%M:%S')] CCLRTE-RT: $*" | tee -a "$LOG"
}

log "Starting real-time system setup (PREEMPT_RT)"

# ── 1. IRQ affinity — pin all IRQs to CPU0,1 ─────────────────────────────────
# EtherCAT and CODESYS CPUs (2,3) must not be interrupted by device IRQs.
log "Setting default IRQ affinity to CPU0,1 (bitmask 0x3)"
echo 3 > /proc/irq/default_smp_affinity 2>/dev/null || true
for irq_dir in /proc/irq/*/; do
    irq=$(basename "$irq_dir")
    [[ "$irq" == "default_smp_affinity" ]] && continue
    echo "3" > "${irq_dir}smp_affinity" 2>/dev/null || true   # 0x3 = CPU0,1
done

# ── 2. EtherCAT NIC IRQ → CPU2 ───────────────────────────────────────────────
# Move the EtherCAT NIC's IRQ to CPU2 so the kernel NIC handler and IgH
# master thread share the same CPU — reduces cross-CPU cache misses.
ETHERCAT_IF=${ETHERCAT_IF:-eth1}
log "Pinning ${ETHERCAT_IF} IRQ to CPU2"
if ETH_IRQ=$(grep "${ETHERCAT_IF}" /proc/interrupts 2>/dev/null | awk -F: '{print $1}' | tr -d ' ' | head -n 1); then
    if [[ -n "$ETH_IRQ" ]]; then
        echo "4" > "/proc/irq/${ETH_IRQ}/smp_affinity" 2>/dev/null || true   # 0x4 = CPU2
        log "  ${ETHERCAT_IF} IRQ ${ETH_IRQ} pinned to CPU2"
    else
        log "  ${ETHERCAT_IF} not found in /proc/interrupts — set ETHERCAT_IF in /etc/ethercat.conf"
    fi
fi

# ── 3. Remove RT bandwidth throttle ──────────────────────────────────────────
# Default Linux cap: RT tasks can use at most 95% CPU time per period.
# With isolated CPUs and a hardware watchdog this is safe to remove.
log "Removing RT bandwidth throttle (sched_rt_runtime_us=-1)"
sysctl -w kernel.sched_rt_runtime_us=-1

# ── 4. Memory tuning ─────────────────────────────────────────────────────────
log "Disabling swap (prevents page-fault latency on CODESYS CPU)"
sysctl -w vm.swappiness=0

# ── 5. CPU governor — enforce performance (already locked by force_turbo=1) ───
log "Setting cpufreq governor to performance on all CPUs"
for cpu_gov in /sys/devices/system/cpu/cpu*/cpufreq/scaling_governor; do
    [[ -f "$cpu_gov" ]] && echo performance > "$cpu_gov" 2>/dev/null || true
done

# ── 6. Log CPU temperature at startup ─────────────────────────────────────────
if [[ -f /sys/class/thermal/thermal_zone0/temp ]]; then
    TEMP_MC=$(cat /sys/class/thermal/thermal_zone0/temp)
    TEMP_C=$(( TEMP_MC / 1000 ))
    log "CPU temperature at RT setup: ${TEMP_C} °C"
    if (( TEMP_C >= 75 )); then
        log "WARNING: CPU temperature >= 75 °C — check airflow / heatsink"
    fi
fi

log "Real-time system setup complete"
log "  CPU freq: $(cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_cur_freq 2>/dev/null || echo unknown) kHz (locked, force_turbo=1)"
log "  EtherCAT (CPU2, SCHED_FIFO 90): configured by ethercat.service unit"
log "  CODESYS  (CPU3, SCHED_FIFO 80): configured by rt-override.conf drop-in"
log "  Target CODESYS scan cycle: 500 µs — set in IDE Task Configuration (T#500us)"
log "  Verify latency: cyclictest -m -p 90 -t 1 -a 3 -l 600000 -i 500"
