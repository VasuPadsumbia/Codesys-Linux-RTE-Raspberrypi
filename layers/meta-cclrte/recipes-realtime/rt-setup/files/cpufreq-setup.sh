#!/bin/bash
# CCLRTE CPU Frequency Setup
# Sets all CPUs to performance governor and disables C-states on RT CPUs.
# Called by rt-setup.service before rt-setup.sh.

set -euo pipefail

log() { echo "[$(date -Iseconds)] CCLRTE-CPUFREQ: $*"; }

# ── 1. Set performance governor on all CPUs ───────────────────────────────────
log "Setting CPU frequency governor to 'performance' on all CPUs"
for cpu in /sys/devices/system/cpu/cpu[0-9]*/cpufreq/scaling_governor; do
    [[ -f "$cpu" ]] && echo "performance" > "$cpu" && log "  $(dirname "$cpu" | xargs basename): performance"
done

# ── 2. Disable C-states on RT CPUs (CPU2 and CPU3) ───────────────────────────
log "Disabling CPU idle states (C-states) on CPU2 and CPU3"
for cpu in 2 3; do
    for state in /sys/devices/system/cpu/cpu${cpu}/cpuidle/state*/disable; do
        [[ -f "$state" ]] && echo "1" > "$state"
    done
    log "  CPU${cpu}: all C-states disabled"
done

# ── 3. Pin min = max frequency on RT CPUs ────────────────────────────────────
for cpu in 2 3; do
    CPUFREQ=/sys/devices/system/cpu/cpu${cpu}/cpufreq
    if [[ -f "${CPUFREQ}/scaling_max_freq" ]]; then
        MAX=$(cat "${CPUFREQ}/scaling_max_freq")
        echo "$MAX" > "${CPUFREQ}/scaling_min_freq" 2>/dev/null || true
        log "  CPU${cpu}: min_freq pinned to ${MAX} Hz"
    fi
done

log "CPU frequency setup complete"
