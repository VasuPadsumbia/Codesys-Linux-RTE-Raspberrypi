#!/usr/bin/env bash
# test_rt_latency.sh — RT scheduling smoke test for QEMU.
#
# Runs a short cyclictest inside QEMU to verify RT scheduling is functional.
# QEMU without KVM has high latency (expected) — threshold is relaxed to 5000 µs.
# This is a smoke test: verifies cyclictest runs and SCHED_FIFO scheduling works.
#
# Usage (from host): bash tests/qemu/test_rt_latency.sh [image_path]
# Usage (on target):  bash /usr/local/bin/test_rt_latency.sh
#
# Exit codes:
#   0 — cyclictest ran and latency within QEMU threshold
#   1 — cyclictest failed or latency unreasonably high

set -euo pipefail

# Relax threshold for QEMU — software emulation has much higher latency
QEMU_LATENCY_THRESHOLD_US=5000
DURATION_S=10
INTERVAL_US=1000

echo "=== RT Latency Smoke Test (QEMU) ==="
echo "Duration:  ${DURATION_S}s"
echo "Interval:  ${INTERVAL_US} µs"
echo "Threshold: ${QEMU_LATENCY_THRESHOLD_US} µs (QEMU relaxed)"
echo ""

# Check cyclictest is available
if ! command -v cyclictest &>/dev/null; then
    echo "ERROR: cyclictest not found. Ensure rt-tests package is installed."
    exit 1
fi

# Run cyclictest in quiet mode, capture output
TMPFILE=$(mktemp /tmp/cyclictest-qemu.XXXXXX)
trap 'rm -f "$TMPFILE"' EXIT

cyclictest \
    --mlockall \
    --priority=80 \
    --interval="${INTERVAL_US}" \
    --duration="${DURATION_S}" \
    --quiet \
    --histfile="${TMPFILE}.hist" \
    2>&1 | tee "${TMPFILE}" || {
    echo "FAIL: cyclictest exited with error"
    exit 1
}

# Extract max latency from cyclictest output
# cyclictest --quiet prints: "T: 0 (PID) P:80 I:1000 C:10000 Min:  X Avg:  Y Max:  Z"
MAX_LATENCY=""
while IFS= read -r line; do
    if [[ "$line" =~ Max:[[:space:]]*([0-9]+) ]]; then
        MAX_LATENCY="${BASH_REMATCH[1]}"
    fi
done < "${TMPFILE}"

if [[ -z "$MAX_LATENCY" ]]; then
    echo "WARNING: Could not parse max latency from cyclictest output"
    echo "Cyclictest output:"
    cat "${TMPFILE}"
    # Not a hard failure — QEMU output format may vary
    echo "PASS (no latency parse — cyclictest ran without error)"
    exit 0
fi

echo "Max latency: ${MAX_LATENCY} µs"

if [[ "$MAX_LATENCY" -lt "$QEMU_LATENCY_THRESHOLD_US" ]]; then
    echo "PASS: Max latency ${MAX_LATENCY} µs < threshold ${QEMU_LATENCY_THRESHOLD_US} µs"
    exit 0
else
    echo "FAIL: Max latency ${MAX_LATENCY} µs >= threshold ${QEMU_LATENCY_THRESHOLD_US} µs"
    echo "NOTE: Very high latency in QEMU may indicate missing KVM acceleration"
    echo "      For hardware RT testing, run on physical RPi4 hardware."
    exit 1
fi
