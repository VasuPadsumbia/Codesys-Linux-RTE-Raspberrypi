#!/bin/bash
# CCLRTE Watchdog Repair Script
# ============================================================
# Location: /usr/sbin/cclrte-watchdog-repair.sh
# Called by the watchdog daemon (via repair-binary) BEFORE it
# triggers a hard hardware reboot.  If this script exits 0 the
# watchdog daemon suppresses the reboot and keeps monitoring.
# If it exits non-zero the daemon proceeds with the reboot.
#
# Strategy:
#   1. Try to restart CODESYS Control (codesyscontrol.service)
#   2. Try to restart EtherCAT master  (ethercat.service)
#   3. Log everything to /var/log for post-mortem analysis
#
# The BCM2712 hardware watchdog timeout is 15 s; we set
# watchdog-timeout = 10 s in watchdog.conf so the daemon
# has 5 s to complete repair before the hardware fires.
# ============================================================

set -uo pipefail

LOG_FILE="/var/log/cclrte-watchdog-repair.log"
TIMESTAMP=$(date -Iseconds 2>/dev/null || date)

log() {
    echo "[$TIMESTAMP] CCLRTE-WATCHDOG-REPAIR: $*" | tee -a "$LOG_FILE"
}

# ── Ensure log directory exists ──────────────────────────────
mkdir -p "$(dirname "$LOG_FILE")"

log "============================================="
log "Watchdog repair triggered — attempting recovery"
log "Uptime: $(uptime)"

EXIT_CODE=0

# ── Restart CODESYS Control ──────────────────────────────────
if systemctl is-enabled codesyscontrol.service >/dev/null 2>&1; then
    log "Restarting codesyscontrol.service ..."
    if systemctl restart codesyscontrol.service 2>&1 | tee -a "$LOG_FILE"; then
        log "codesyscontrol restarted successfully"
    else
        log "WARNING: codesyscontrol restart failed — reboot required"
        EXIT_CODE=1
    fi
else
    log "codesyscontrol.service not enabled, skipping"
fi

# ── Restart IgH EtherCAT master ─────────────────────────────
if systemctl is-enabled ethercat.service >/dev/null 2>&1; then
    log "Restarting ethercat.service ..."
    if systemctl restart ethercat.service 2>&1 | tee -a "$LOG_FILE"; then
        log "ethercat restarted successfully"
    else
        log "WARNING: ethercat restart failed"
        # Not fatal on its own — CODESYS may recover without it
    fi
else
    log "ethercat.service not enabled, skipping"
fi

# ── Collect system state for diagnostics ─────────────────────
{
    echo "--- dmesg tail ---"
    dmesg --time-format iso 2>/dev/null | tail -30 || dmesg | tail -30
    echo "--- systemctl failed units ---"
    systemctl --failed --no-pager 2>/dev/null || true
} >> "$LOG_FILE" 2>&1

log "Repair complete — exit code: $EXIT_CODE"
log "============================================="

# Exit 0  → watchdog suppresses reboot, keeps monitoring
# Exit ≠0 → watchdog proceeds with hardware reboot
exit $EXIT_CODE
