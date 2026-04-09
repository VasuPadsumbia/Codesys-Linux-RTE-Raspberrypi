#!/bin/bash
# CCLRTE RT Latency Verification
# Author: Vasu Padsumbia
# Tests per-CPU latency at the priorities used by EtherCAT (CPU2) and CODESYS (CPU3).
# Runs regardless of whether EtherCAT or CODESYS are active — tests kernel RT, not apps.
# Results written to /var/log/cclrte-rt-result.txt (JSON).

set -uo pipefail

RESULT_FILE=/var/log/cclrte-rt-result.txt
HISTOGRAM_DIR=/var/log/cclrte-rt-histograms
PASS_THRESHOLD_US=100   # µs — max allowed worst-case for motion control
DURATION_SEC=60         # seconds per test phase
INTERVAL_US=500         # µs — matches CODESYS 500µs scan cycle target

# BusyBox-compatible timestamp (no -Iseconds)
ts() { date '+%Y-%m-%dT%H:%M:%S'; }
log() { echo "[$(ts)] CCLRTE-RTVERIFY: $*"; }

log "Starting RT latency verification"
log "  Duration per phase : ${DURATION_SEC}s"
log "  Interval           : ${INTERVAL_US}µs"
log "  Pass threshold     : ${PASS_THRESHOLD_US}µs"
log "  CODESYS/EtherCAT do NOT need to be running — this tests kernel RT latency"

mkdir -p "$HISTOGRAM_DIR"

# ── Run cyclictest on a specific CPU, return max latency in µs ────────────────
# Usage: run_phase <cpu_num> <priority> <label>
run_phase() {
    local cpu="$1" prio="$2" label="$3"
    local histfile="${HISTOGRAM_DIR}/hist-cpu${cpu}.txt"

    log "Phase: ${label} — CPU${cpu}, SCHED_FIFO priority ${prio}"

    local out
    out=$(cyclictest \
        --mlockall \
        --affinity="${cpu}" \
        --threads=1 \
        --priority="${prio}" \
        --interval="${INTERVAL_US}" \
        --distance=0 \
        --duration="${DURATION_SEC}" \
        --histogram=500 \
        --histfile="${histfile}" \
        --quiet 2>&1) || true

    # Parse max and avg from quiet output:
    # Format: "T: 0 (  pid) I:   500 C: NNN Min:    N Act:    N Avg:    N Max:    N"
    local max avg
    max=$(echo "$out" | awk '/^T:/{m=$NF; if(m+0>max) max=m+0} END{print max+0}')
    avg=$(echo "$out" | awk '/^T:/{sum+=$(NF-2); n++} END{print (n>0)?int(sum/n):0}')

    [[ -z "$max" || "$max" == "0" ]] && {
        # Fallback: try "Max Latencies" line from non-quiet output
        max=$(echo "$out" | awk '/Max Latencies/{for(i=3;i<=NF;i++) if($i+0>m) m=$i+0; print m+0}')
    }
    max=${max:-0}
    avg=${avg:-0}

    log "  CPU${cpu} result: max=${max}µs avg=${avg}µs"
    echo "${max} ${avg}"
}

# ── Phase 1: All-CPU SMP baseline (OS noise test) ────────────────────────────
log "=== Phase 1/3: All-CPU SMP baseline (priority 80) ==="
SMP_OUT=$(cyclictest \
    --mlockall \
    --smp \
    --priority=80 \
    --interval="${INTERVAL_US}" \
    --distance=0 \
    --duration="${DURATION_SEC}" \
    --histogram=500 \
    --histfile="${HISTOGRAM_DIR}/hist-smp.txt" \
    --quiet 2>&1) || true

SMP_MAX=$(echo "$SMP_OUT" | awk '/Max Latencies/{for(i=3;i<=NF;i++) if($i+0>m) m=$i+0; print m+0}')
SMP_MAX=${SMP_MAX:-0}
log "SMP max latency: ${SMP_MAX}µs"

# ── Phase 2: CPU2 — EtherCAT master (SCHED_FIFO 90) ──────────────────────────
log "=== Phase 2/3: CPU2 — EtherCAT priority (SCHED_FIFO 90) ==="
read -r CPU2_MAX CPU2_AVG <<< "$(run_phase 2 90 'EtherCAT-CPU2')"

# ── Phase 3: CPU3 — CODESYS scan cycle (SCHED_FIFO 80) ───────────────────────
log "=== Phase 3/3: CPU3 — CODESYS priority (SCHED_FIFO 80) ==="
read -r CPU3_MAX CPU3_AVG <<< "$(run_phase 3 80 'CODESYS-CPU3')"

# ── Overall pass/fail: worst of CPU2 and CPU3 (the RT-critical cores) ─────────
WORST_MAX=$(( CPU2_MAX > CPU3_MAX ? CPU2_MAX : CPU3_MAX ))
WORST_MAX=$(( WORST_MAX > SMP_MAX ? WORST_MAX : SMP_MAX ))

if [[ "$WORST_MAX" -le "$PASS_THRESHOLD_US" ]]; then
    STATUS="PASS"
    log "PASS: worst-case latency ${WORST_MAX}µs <= threshold ${PASS_THRESHOLD_US}µs"
else
    STATUS="FAIL"
    log "FAIL: worst-case latency ${WORST_MAX}µs > threshold ${PASS_THRESHOLD_US}µs"
    if [[ "$CPU2_MAX" -gt "$PASS_THRESHOLD_US" ]]; then
        log "  → CPU2 (EtherCAT): ${CPU2_MAX}µs — check IRQ affinity (rt-setup.service)"
    fi
    if [[ "$CPU3_MAX" -gt "$PASS_THRESHOLD_US" ]]; then
        log "  → CPU3 (CODESYS): ${CPU3_MAX}µs — consider Xenomai build target"
        log "     Build: ./cclrte.sh build xenomai"
    fi
fi

TIMESTAMP=$(ts)
cat > "$RESULT_FILE" <<EOF
{
  "timestamp": "${TIMESTAMP}",
  "status": "${STATUS}",
  "threshold_us": ${PASS_THRESHOLD_US},
  "duration_sec": ${DURATION_SEC},
  "interval_us": ${INTERVAL_US},
  "smp_max_us":   ${SMP_MAX},
  "cpu2_ethercat": { "max_us": ${CPU2_MAX}, "avg_us": ${CPU2_AVG}, "priority": 90 },
  "cpu3_codesys":  { "max_us": ${CPU3_MAX}, "avg_us": ${CPU3_AVG}, "priority": 80 },
  "worst_max_us":  ${WORST_MAX},
  "histogram_dir": "${HISTOGRAM_DIR}"
}
EOF

log "Result written to ${RESULT_FILE}"
[[ "$STATUS" == "PASS" ]] && exit 0 || exit 1
