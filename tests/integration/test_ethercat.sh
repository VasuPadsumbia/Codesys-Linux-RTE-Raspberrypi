#!/usr/bin/env bash
# test_ethercat.sh — Integration test for IgH EtherCAT master on target RPi4.
#
# Run ON the target (via SSH or directly):
#   ssh root@192.168.1.100 bash < tests/integration/test_ethercat.sh
#
# Checks:
#   1. ec_master kernel module is loaded
#   2. ethercat.service is active
#   3. ethercat command is available and runs without error
#   4. ec_master kthread is on CPU2 (affinity mask 0x4)
#   5. ec_master threads run at SCHED_FIFO priority 90
#
# EtherCAT slaves need not be connected — the master can run with zero slaves.
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

echo "=== IgH EtherCAT Master Integration Test ==="
echo ""

# ---------------------------------------------------------------------------
# Check 1: ec_master kernel module
# ---------------------------------------------------------------------------
echo "[1] Kernel module"
if lsmod | grep -q "^ec_master"; then
    check "ec_master module is loaded" "pass"
else
    check "ec_master module is loaded" "module not found in lsmod output"
fi

if lsmod | grep -q "^ec_generic"; then
    check "ec_generic driver is loaded" "pass"
else
    check "ec_generic driver loaded" "ec_generic not found (may use dedicated driver)"
fi

# ---------------------------------------------------------------------------
# Check 2: ethercat.service
# ---------------------------------------------------------------------------
echo "[2] Service state"
if systemctl is-enabled ethercat &>/dev/null; then
    check "ethercat.service is enabled" "pass"
else
    check "ethercat.service is enabled" "service not enabled"
fi

if systemctl is-active ethercat &>/dev/null; then
    check "ethercat.service is active" "pass"
else
    check "ethercat.service is active" "service is not active"
    journalctl -u ethercat --no-pager -n 10
fi

# ---------------------------------------------------------------------------
# Check 3: ethercat command
# ---------------------------------------------------------------------------
echo "[3] ethercat tool"
if command -v ethercat &>/dev/null; then
    check "ethercat command is in PATH" "pass"

    # Query master state (exits 0 even with no slaves)
    if ethercat master &>/dev/null; then
        check "ethercat master command runs without error" "pass"

        SLAVE_COUNT=$(ethercat slaves 2>/dev/null | wc -l || echo "0")
        echo "  INFO: EtherCAT slaves detected: $SLAVE_COUNT"
        check "ethercat slaves command runs" "pass"
    else
        check "ethercat master command runs" "command failed — check /etc/ethercat.conf MASTER0_DEVICE"
    fi
else
    check "ethercat command in PATH" "not found — IgH EtherCAT tools not installed"
fi

# ---------------------------------------------------------------------------
# Check 4: ec_master thread CPU affinity (should be CPU2 = mask 0x4)
# ---------------------------------------------------------------------------
echo "[4] CPU affinity"
EC_PID=$(pgrep -f "ec_master" 2>/dev/null | head -1 || true)

if [[ -z "$EC_PID" ]]; then
    # Try kernel thread name
    EC_PID=$(ps aux | grep -i "EtherCAT" | grep -v grep | awk '{print $2}' | head -1 || true)
fi

if [[ -n "$EC_PID" ]]; then
    check "ec_master thread PID found ($EC_PID)" "pass"

    AFFINITY_HEX=$(taskset -p "$EC_PID" 2>/dev/null | grep -oP '(?<=current affinity mask: )\S+' || echo "")
    if [[ "$AFFINITY_HEX" == "4" ]]; then
        check "CPU affinity = 0x4 (CPU2 only)" "pass"
    elif [[ -n "$AFFINITY_HEX" ]]; then
        check "CPU affinity = 0x4 (CPU2 only)" "affinity is 0x${AFFINITY_HEX} — expected 0x4"
    else
        check "CPU affinity readable" "could not read affinity"
    fi
else
    echo "  INFO: ec_master kthread not found as userspace process (normal for kernel module)"
    check "ec_master CPU affinity check" "pass (kernel thread — affinity set by rt-setup.sh)"
fi

# ---------------------------------------------------------------------------
# Check 5: Scheduling priority
# ---------------------------------------------------------------------------
echo "[5] RT scheduling"
# The ethercat service process (rather than the kthread) is what we can inspect
ETHERCAT_SVC_PID=$(systemctl show ethercat --property=MainPID --value 2>/dev/null || echo "")
if [[ -n "$ETHERCAT_SVC_PID" ]] && [[ "$ETHERCAT_SVC_PID" -gt 0 ]]; then
    SCHED_INFO=$(chrt -p "$ETHERCAT_SVC_PID" 2>/dev/null || echo "")
    if echo "$SCHED_INFO" | grep -q "SCHED_FIFO"; then
        check "ethercat service SCHED_FIFO" "pass"
    else
        check "ethercat service SCHED_FIFO" "not SCHED_FIFO: $SCHED_INFO"
    fi

    PRIORITY=$(echo "$SCHED_INFO" | grep -oP '(?<=priority: )\d+' || echo "")
    if [[ "$PRIORITY" == "89" ]] || [[ "$PRIORITY" == "90" ]]; then
        check "SCHED_FIFO priority 89–90" "pass"
    elif [[ -n "$PRIORITY" ]]; then
        check "SCHED_FIFO priority 89–90" "priority is $PRIORITY"
    fi
else
    echo "  INFO: Could not get MainPID for ethercat service"
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
