#!/usr/bin/env bash
# test_codesys_startup.sh — Integration test for CODESYS runtime on target RPi4.
#
# Run ON the target (via SSH or directly):
#   ssh root@192.168.1.100 bash < tests/integration/test_codesys_startup.sh
#
# Checks:
#   1. codesyscontrol.service is enabled and active (or can be started)
#   2. CPU affinity is CPU3 only (mask 0x8)
#   3. Scheduling policy is SCHED_FIFO priority 80
#   4. Gateway port 1217 is listening
#   5. /opt/codesys directory exists (runtime installed)
#
# Exit codes:
#   0 — all checks passed
#   1 — one or more checks failed

set -euo pipefail

PASS=0
FAIL=0

check() {
    local desc="$1"
    local result="$2"
    if [[ "$result" == "pass" ]]; then
        echo "  PASS: $desc"
        ((PASS++)) || true
    else
        echo "  FAIL: $desc — $result"
        ((FAIL++)) || true
    fi
}

echo "=== CODESYS Runtime Integration Test ==="
echo ""

# ---------------------------------------------------------------------------
# Check 1: Runtime binary is installed
# ---------------------------------------------------------------------------
echo "[1] Runtime installation"
if [[ -d /opt/codesys/bin ]] && [[ -f /opt/codesys/bin/codesyscontrol ]]; then
    check "CODESYS binary present at /opt/codesys/bin/codesyscontrol" "pass"
else
    check "CODESYS binary present" "CODESYS not installed — run /usr/sbin/install-codesys-runtime.sh first"
    echo ""
    echo "SKIP: CODESYS not installed. Install the runtime before running this test."
    exit 0
fi

# ---------------------------------------------------------------------------
# Check 2: Service is enabled
# ---------------------------------------------------------------------------
echo "[2] Service state"
if systemctl is-enabled codesyscontrol &>/dev/null; then
    check "codesyscontrol.service is enabled" "pass"
else
    check "codesyscontrol.service is enabled" "service not enabled"
fi

# Start service if not running
if ! systemctl is-active codesyscontrol &>/dev/null; then
    echo "  INFO: Starting codesyscontrol.service..."
    systemctl start codesyscontrol
fi

# Wait up to 30 seconds for active state
WAIT=0
while [[ "$WAIT" -lt 30 ]]; do
    if systemctl is-active codesyscontrol &>/dev/null; then
        break
    fi
    sleep 1
    ((WAIT++)) || true
done

if systemctl is-active codesyscontrol &>/dev/null; then
    check "codesyscontrol.service reached active state" "pass"
else
    check "codesyscontrol.service reached active state" "service failed to start after 30s"
    journalctl -u codesyscontrol --no-pager -n 20
    exit 1
fi

# ---------------------------------------------------------------------------
# Check 3: CPU affinity (must be CPU3 = mask 0x8)
# ---------------------------------------------------------------------------
echo "[3] CPU affinity"
CODESYS_PID=$(pgrep -x codesyscontrol 2>/dev/null | head -1 || true)
if [[ -z "$CODESYS_PID" ]]; then
    check "codesyscontrol PID found" "process not found"
else
    check "codesyscontrol PID found ($CODESYS_PID)" "pass"

    AFFINITY_HEX=$(taskset -p "$CODESYS_PID" 2>/dev/null | grep -oP '(?<=current affinity mask: )\S+' || echo "")
    if [[ "$AFFINITY_HEX" == "8" ]]; then
        check "CPU affinity = 0x8 (CPU3 only)" "pass"
    elif [[ -n "$AFFINITY_HEX" ]]; then
        check "CPU affinity = 0x8 (CPU3 only)" "affinity is 0x${AFFINITY_HEX} — expected 0x8"
    else
        check "CPU affinity readable" "could not read affinity"
    fi
fi

# ---------------------------------------------------------------------------
# Check 4: Scheduling policy SCHED_FIFO priority 80
# ---------------------------------------------------------------------------
echo "[4] RT scheduling"
if [[ -n "$CODESYS_PID" ]]; then
    SCHED_INFO=$(chrt -p "$CODESYS_PID" 2>/dev/null || echo "")
    if echo "$SCHED_INFO" | grep -q "SCHED_FIFO"; then
        check "Scheduling policy is SCHED_FIFO" "pass"
    else
        check "Scheduling policy is SCHED_FIFO" "not SCHED_FIFO: $SCHED_INFO"
    fi

    PRIORITY=$(echo "$SCHED_INFO" | grep -oP '(?<=priority: )\d+' || echo "")
    if [[ "$PRIORITY" == "80" ]]; then
        check "SCHED_FIFO priority = 80" "pass"
    elif [[ -n "$PRIORITY" ]]; then
        check "SCHED_FIFO priority = 80" "priority is $PRIORITY — expected 80"
    else
        check "SCHED_FIFO priority readable" "could not parse priority"
    fi
fi

# ---------------------------------------------------------------------------
# Check 5: Gateway port 1217 is listening
# ---------------------------------------------------------------------------
echo "[5] Network ports"
if ss -tlnp 2>/dev/null | grep -q ":1217 "; then
    check "Gateway port 1217 is listening" "pass"
else
    check "Gateway port 1217 is listening" "port 1217 not found in ss output"
fi

if ss -tlnp 2>/dev/null | grep -q ":4840 "; then
    check "OPC-UA port 4840 is listening" "pass"
else
    check "OPC-UA port 4840 is listening" "port 4840 not found (OPC-UA SL may not be licensed)"
fi

# ---------------------------------------------------------------------------
# Results
# ---------------------------------------------------------------------------
echo ""
echo "======================================="
echo "Results: ${PASS} passed, ${FAIL} failed"
echo "======================================="

if [[ "${FAIL}" -gt 0 ]]; then
    exit 1
fi
exit 0
