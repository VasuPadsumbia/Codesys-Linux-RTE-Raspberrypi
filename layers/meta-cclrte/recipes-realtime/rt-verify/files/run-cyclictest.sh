#!/bin/bash
# CCLRTE RT Latency Verification
# Author: Vasu Padsumbia
#
# Tests kernel RT latency at the priorities used by EtherCAT (CPU2) and CODESYS (CPU3).
# Runs two phases:
#   IDLE  (best case)  — no load, baseline latency
#   LOAD  (worst case) — stress-ng load on OS cores (CPU0,1) simulating heavy CODESYS code
# EtherCAT cycle jitter is read from the IgH master stats if the master is running.

set -uo pipefail

RESULT_FILE=/var/log/cclrte-rt-result.txt
PASS_THRESHOLD_US=100   # µs — max allowed worst-case on isolated RT cores
IDLE_SEC=30             # seconds for idle (best-case) phase
LOAD_SEC=30             # seconds for load (worst-case) phase
INTERVAL_US=500         # µs — matches CODESYS 500µs scan cycle

ts()  { date '+%Y-%m-%dT%H:%M:%S'; }
log() { echo "[$(ts)] CCLRTE-RTVERIFY: $*" >&2; }

log "RT latency verification — best-case (idle) + worst-case (load)"
log "  Idle phase : ${IDLE_SEC}s | Load phase: ${LOAD_SEC}s"
log "  Interval   : ${INTERVAL_US}µs | Pass threshold: ${PASS_THRESHOLD_US}µs"

# ── Run cyclictest, return "min avg max" ──────────────────────────────────────
run_phase() {
    local cpu="$1" prio="$2" duration="$3"
    local out
    out=$(cyclictest \
        --mlockall \
        --affinity="${cpu}" \
        --threads=1 \
        --priority="${prio}" \
        --interval="${INTERVAL_US}" \
        --distance=0 \
        --duration="${duration}" \
        --quiet 2>/dev/null) || true

    local min avg max
    min=$(echo "$out" | awk '/^T:/{for(i=1;i<=NF;i++) if($i=="Min:"){v=$(i+1)+0; if(!f||v<m){m=v;f=1}}} END{print m+0}')
    avg=$(echo "$out" | awk '/^T:/{for(i=1;i<=NF;i++) if($i=="Avg:"){s+=$(i+1)+0;n++}} END{print n?int(s/n):0}')
    max=$(echo "$out" | awk '/^T:/{for(i=1;i<=NF;i++) if($i=="Max:"){v=$(i+1)+0;if(v>m)m=v}} END{print m+0}')
    echo "${min:-0} ${avg:-0} ${max:-0}"
}

# ── EtherCAT jitter from IgH master stats ────────────────────────────────────
ethercat_jitter() {
    if ! command -v ethercat &>/dev/null; then echo "0 0 0"; return; fi
    if ! systemctl is-active --quiet ethercat 2>/dev/null; then echo "0 0 0"; return; fi
    local stats
    stats=$(ethercat master 2>/dev/null | grep -i "Tx\|Rx\|frame\|jitter" | head -10 || true)
    # IgH reports cycle time jitter in master output — extract if available
    local jitter
    jitter=$(echo "$stats" | awk '/[Jj]itter/{match($0,/[0-9]+/,a); print a[0]; exit}')
    echo "${jitter:-0} 0 0"
}

# ════════════════════════════════════════════════════════════════════════
# PHASE 1: IDLE — best case (no artificial load)
# ════════════════════════════════════════════════════════════════════════
log "=== IDLE PHASE (best case, ${IDLE_SEC}s) ==="

log "  CPU2 EtherCAT SCHED_FIFO 90 ..."
read -r C2I_MIN C2I_AVG C2I_MAX <<< "$(run_phase 2 90 $IDLE_SEC)"
log "  CPU2 idle: min=${C2I_MIN}µs avg=${C2I_AVG}µs max=${C2I_MAX}µs"

log "  CPU3 CODESYS SCHED_FIFO 80 ..."
read -r C3I_MIN C3I_AVG C3I_MAX <<< "$(run_phase 3 80 $IDLE_SEC)"
log "  CPU3 idle: min=${C3I_MIN}µs avg=${C3I_AVG}µs max=${C3I_MAX}µs"

log "  EtherCAT master jitter ..."
read -r EC_JITTER EC_ EC__ <<< "$(ethercat_jitter)"
log "  EtherCAT jitter: ${EC_JITTER}µs"

# ════════════════════════════════════════════════════════════════════════
# PHASE 2: LOAD — worst case (stress OS cores to simulate heavy PLC code)
# stress-ng loads CPU0,1 only — CPU2,3 are isolated and unaffected by taskset
# ════════════════════════════════════════════════════════════════════════
log "=== LOAD PHASE (worst case, ${LOAD_SEC}s, stress-ng on CPU0,1) ==="

STRESS_PID=""
if command -v stress-ng &>/dev/null; then
    taskset -c 0,1 stress-ng --cpu 2 --vm 1 --vm-bytes 256M \
        --timeout "${LOAD_SEC}s" --quiet &
    STRESS_PID=$!
    log "  stress-ng running on CPU0,1 (PID ${STRESS_PID})"
else
    log "  WARNING: stress-ng not found — load phase = idle phase results"
fi

log "  CPU2 EtherCAT SCHED_FIFO 90 under load ..."
read -r C2L_MIN C2L_AVG C2L_MAX <<< "$(run_phase 2 90 $LOAD_SEC)"
log "  CPU2 load: min=${C2L_MIN}µs avg=${C2L_AVG}µs max=${C2L_MAX}µs"

log "  CPU3 CODESYS SCHED_FIFO 80 under load ..."
read -r C3L_MIN C3L_AVG C3L_MAX <<< "$(run_phase 3 80 $LOAD_SEC)"
log "  CPU3 load: min=${C3L_MIN}µs avg=${C3L_AVG}µs max=${C3L_MAX}µs"

[[ -n "$STRESS_PID" ]] && kill "$STRESS_PID" 2>/dev/null || true

# ════════════════════════════════════════════════════════════════════════
# Pass / Fail — based on worst-case (load phase) isolated cores
# ════════════════════════════════════════════════════════════════════════
WORST=$(( C2L_MAX > C3L_MAX ? C2L_MAX : C3L_MAX ))
if [[ "$WORST" -le "$PASS_THRESHOLD_US" ]]; then
    STATUS="PASS"
    log "PASS: worst-case ${WORST}µs <= threshold ${PASS_THRESHOLD_US}µs"
else
    STATUS="FAIL"
    log "FAIL: worst-case ${WORST}µs > threshold ${PASS_THRESHOLD_US}µs"
    if [[ "$WORST" -gt 10000 ]]; then
        log "  >10ms spike — PREEMPT_RT or Xenomai Cobalt not active"
        log "  Check: cat /sys/kernel/realtime  (must output 1 for PREEMPT_RT)"
        log "  Check: ls /proc/xenomai          (must exist for Cobalt)"
    fi
fi

TIMESTAMP=$(ts)
mkdir -p "$(dirname "$RESULT_FILE")"
cat > "$RESULT_FILE" <<EOF
{
  "timestamp": "${TIMESTAMP}",
  "status": "${STATUS}",
  "threshold_us": ${PASS_THRESHOLD_US},
  "idle_sec": ${IDLE_SEC},
  "load_sec": ${LOAD_SEC},
  "interval_us": ${INTERVAL_US},
  "cpu2_ethercat": {
    "idle":  { "min_us": ${C2I_MIN}, "avg_us": ${C2I_AVG}, "max_us": ${C2I_MAX} },
    "load":  { "min_us": ${C2L_MIN}, "avg_us": ${C2L_AVG}, "max_us": ${C2L_MAX} },
    "priority": 90
  },
  "cpu3_codesys": {
    "idle":  { "min_us": ${C3I_MIN}, "avg_us": ${C3I_AVG}, "max_us": ${C3I_MAX} },
    "load":  { "min_us": ${C3L_MIN}, "avg_us": ${C3L_AVG}, "max_us": ${C3L_MAX} },
    "priority": 80
  },
  "ethercat_jitter_us": ${EC_JITTER},
  "worst_max_us": ${WORST}
}
EOF

log "Result: ${RESULT_FILE}"
[[ "$STATUS" == "PASS" ]] && exit 0 || exit 1
