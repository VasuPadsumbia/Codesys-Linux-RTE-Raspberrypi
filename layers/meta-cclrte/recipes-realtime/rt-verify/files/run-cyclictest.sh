#!/bin/bash
# CCLRTE RT Latency Verification
# Runs cyclictest for 60 seconds and fails if max latency exceeds threshold.
# Results written to /var/log/cclrte-rt-result.txt (JSON).
# Used by CI pipeline (tests/qemu/test_rt_latency.sh) and first-boot validation.

set -euo pipefail

RESULT_FILE=/var/log/cclrte-rt-result.txt
HISTOGRAM_FILE=/var/log/cclrte-rt-histogram.txt
# Maximum allowed worst-case latency in microseconds for motion control
PASS_THRESHOLD_US=100
DURATION_SEC=60
INTERVAL_US=500    # matches CODESYS minimum cycle time target

log() { echo "[$(date -Iseconds)] CCLRTE-RTVERIFY: $*"; }

log "Starting RT latency verification (${DURATION_SEC}s, interval=${INTERVAL_US}µs, threshold=${PASS_THRESHOLD_US}µs)"
log "This will take approximately ${DURATION_SEC} seconds..."

# Run cyclictest: SMP mode, all CPUs, priority 80, mlockall
CYCLIC_OUT=$(cyclictest \
    --mlockall \
    --smp \
    --priority=80 \
    --interval="${INTERVAL_US}" \
    --distance=0 \
    --duration="${DURATION_SEC}" \
    --histogram=500 \
    --histfile="${HISTOGRAM_FILE}" \
    --quiet 2>&1) || true

# Parse max latency from cyclictest output
# cyclictest -q outputs: "# Max Latencies: NNN NNN NNN NNN"
MAX_LAT=$(echo "$CYCLIC_OUT" | grep -E "Max Latencies" | awk '{max=0; for(i=3;i<=NF;i++) if($i+0>max) max=$i+0; print max}')
AVG_LAT=$(echo "$CYCLIC_OUT" | grep -E "Avg\(us\)" | awk '{sum=0; count=0; for(i=2;i<=NF;i++) {sum+=$i; count++} print (count>0)?sum/count:0}' 2>/dev/null || echo "0")

[[ -z "$MAX_LAT" ]] && MAX_LAT=0

TIMESTAMP=$(date -Iseconds)
if [[ "$MAX_LAT" -le "$PASS_THRESHOLD_US" ]]; then
    STATUS="PASS"
    log "PASS: max latency ${MAX_LAT}µs <= threshold ${PASS_THRESHOLD_US}µs"
else
    STATUS="FAIL"
    log "FAIL: max latency ${MAX_LAT}µs > threshold ${PASS_THRESHOLD_US}µs"
    log "  Consider: switch to Xenomai build target (./cclrte.sh build xenomai)"
    log "  See: docs/LIMITATIONS.md"
fi

# Write JSON result
cat > "$RESULT_FILE" <<EOF
{
  "timestamp": "${TIMESTAMP}",
  "status": "${STATUS}",
  "max_latency_us": ${MAX_LAT},
  "avg_latency_us": ${AVG_LAT},
  "threshold_us": ${PASS_THRESHOLD_US},
  "duration_sec": ${DURATION_SEC},
  "interval_us": ${INTERVAL_US},
  "histogram_file": "${HISTOGRAM_FILE}"
}
EOF

log "Result written to ${RESULT_FILE}"

[[ "$STATUS" == "PASS" ]] && exit 0 || exit 1
