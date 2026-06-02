#!/usr/bin/env bash
# run_qemu_test.sh — Run the full QEMU test suite against the cclrte-image-qemu build.
#
# Usage: bash tests/qemu/run_qemu_test.sh
#
# Requires:
#   - A completed QEMU build: ./cclrte.sh build qemu
#   - expect(1) for test_boot.expect
#   - venv/bin/activate (created by ./cclrte.sh or manually)

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
BUILD_DIR="${REPO_ROOT}/build"
IMAGE_DIR="${BUILD_DIR}/tmp/deploy/images/qemux86-64"

# ---------------------------------------------------------------------------
# Find the QEMU image
# ---------------------------------------------------------------------------
IMAGE=""
for f in "${IMAGE_DIR}"/cclrte-image-qemu-qemux86-64*.wic \
          "${IMAGE_DIR}"/cclrte-image-qemu-qemux86-64*.wic.bz2 \
          "${IMAGE_DIR}"/cclrte-image-qemu-qemux86-64*.ext4; do
    if [[ -f "$f" ]]; then
        IMAGE="$f"
        break
    fi
done

if [[ -z "$IMAGE" ]]; then
    echo "ERROR: No QEMU image found in ${IMAGE_DIR}"
    echo "       Run './cclrte.sh build qemu' first."
    exit 1
fi

echo "Using image: ${IMAGE}"

# ---------------------------------------------------------------------------
# Activate Python venv
# ---------------------------------------------------------------------------
VENV="${REPO_ROOT}/venv"
if [[ -f "${VENV}/bin/activate" ]]; then
    # shellcheck source=/dev/null
    source "${VENV}/bin/activate"
    echo "Activated venv: ${VENV}"
else
    echo "WARNING: venv not found at ${VENV}, using system Python"
fi

# ---------------------------------------------------------------------------
# Run tests
# ---------------------------------------------------------------------------
PASS=0
FAIL=0

run_test() {
    local name="$1"
    local cmd="$2"
    echo ""
    echo "=== Running: ${name} ==="
    if eval "${cmd}"; then
        echo "PASS: ${name}"
        ((PASS++)) || true
    else
        echo "FAIL: ${name}"
        ((FAIL++)) || true
    fi
}

# Test 1: Boot test via expect script
if command -v expect &>/dev/null; then
    run_test "boot" "expect ${REPO_ROOT}/tests/qemu/test_boot.expect '${IMAGE}'"
else
    echo "WARNING: expect not installed — skipping boot test"
    echo "         Install with: sudo apt install expect"
fi

# Test 2: RT latency smoke test (runs inside QEMU via SSH or expect)
run_test "rt-latency" "bash ${REPO_ROOT}/tests/qemu/test_rt_latency.sh '${IMAGE}'"

# ---------------------------------------------------------------------------
# Results
# ---------------------------------------------------------------------------
echo ""
echo "==============================="
echo "QEMU Test Results: ${PASS} passed, ${FAIL} failed"
echo "==============================="

if [[ "${FAIL}" -gt 0 ]]; then
    exit 1
fi
exit 0
