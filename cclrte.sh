#!/bin/bash
# CCLRTE — CODESYS Control Linux RTE
# Main management script: build / test / clean / load / qemu
# Usage: ./cclrte.sh <command> [options]

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BUILD_DIR="${SCRIPT_DIR}/build"
VENV_DIR="${SCRIPT_DIR}/venv"
KAS_DIR="${SCRIPT_DIR}/kas"

# ── Colors ────────────────────────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
BLUE='\033[0;34m'; CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'

info()    { echo -e "${BLUE}[INFO]${NC}  $*"; }
success() { echo -e "${GREEN}[OK]${NC}    $*"; }
warn()    { echo -e "${YELLOW}[WARN]${NC}  $*"; }
error()   { echo -e "${RED}[ERROR]${NC} $*" >&2; }
die()     { error "$*"; exit 1; }

# ── KAS runner detection ──────────────────────────────────────────────────────
detect_kas() {
    if command -v kas &>/dev/null; then
        echo "kas"
    elif [[ -x "${SCRIPT_DIR}/kas-container" ]]; then
        echo "${SCRIPT_DIR}/kas-container"
    elif command -v docker &>/dev/null; then
        echo "docker run --rm -v ${SCRIPT_DIR}:/work ghcr.io/siemens/kas/kas:latest"
    else
        die "kas, kas-container, or docker not found. Install kas: pip install kas"
    fi
}

# ── venv setup ────────────────────────────────────────────────────────────────
setup_venv() {
    if [[ ! -d "$VENV_DIR" ]]; then
        info "Creating Python virtual environment at venv/"
        python3 -m venv "$VENV_DIR"
        # shellcheck source=/dev/null
        source "${VENV_DIR}/bin/activate"
        pip install --quiet --upgrade pip
        if [[ -f "${SCRIPT_DIR}/requirements.txt" ]]; then
            pip install --quiet -r "${SCRIPT_DIR}/requirements.txt"
        fi
        success "venv created and dependencies installed"
    fi
}

activate_venv() {
    setup_venv
    # shellcheck source=/dev/null
    source "${VENV_DIR}/bin/activate"
}

# ── Build ─────────────────────────────────────────────────────────────────────
cmd_build() {
    local target="${1:-preempt-rt}"
    local kas_file

    case "$target" in
        preempt-rt|rpi4)  kas_file="${KAS_DIR}/rpi4-64.yml" ;;
        xenomai)          kas_file="${KAS_DIR}/rpi4-xenomai.yml" ;;
        qemu)             kas_file="${KAS_DIR}/qemu-x86-64.yml" ;;
        *) die "Unknown build target: $target (use: preempt-rt | xenomai | qemu)" ;;
    esac

    local kas_runner
    kas_runner=$(detect_kas)

    info "Build target : ${BOLD}${target}${NC}"
    info "KAS config   : ${kas_file}"
    info "KAS runner   : ${kas_runner}"
    echo ""

    # kas-container expects path relative to work dir when using docker
    if [[ "$kas_runner" == *"docker"* ]]; then
        $kas_runner build "/work/$(basename "$kas_file")"
    else
        $kas_runner build "$kas_file"
    fi

    success "Build complete: $target"
    echo ""
    info "Image location:"
    case "$target" in
        preempt-rt|rpi4)
            find "${BUILD_DIR}/tmp/deploy/images/rpi4-cclrte" -name "*.rpi-sdimg" 2>/dev/null || true ;;
        xenomai)
            find "${BUILD_DIR}/tmp/deploy/images/rpi4-cclrte-xenomai" -name "*.rpi-sdimg" 2>/dev/null || true ;;
        qemu)
            find "${BUILD_DIR}/tmp/deploy/images/qemux86-64" -name "*.ext4" 2>/dev/null || true ;;
    esac
}

# ── Test ──────────────────────────────────────────────────────────────────────
cmd_test() {
    info "Running CCLRTE test suite"
    activate_venv

    echo ""
    info "── Unit tests ─────────────────────────────────────────"
    python3 -m pytest "${SCRIPT_DIR}/tests/unit/" -v --tb=short 2>&1 || {
        error "Unit tests failed"; exit 1
    }

    echo ""
    info "── QEMU boot test ─────────────────────────────────────"
    local qemu_image
    qemu_image=$(find "${BUILD_DIR}/tmp/deploy/images/qemux86-64" -name "*.ext4" 2>/dev/null | head -1)
    if [[ -n "$qemu_image" ]]; then
        bash "${SCRIPT_DIR}/tests/qemu/run_qemu_test.sh" "$qemu_image"
    else
        warn "QEMU image not found — run './cclrte.sh build qemu' first"
    fi

    success "All tests passed"
}

# ── Clean ─────────────────────────────────────────────────────────────────────
cmd_clean() {
    warn "This will remove: ${BUILD_DIR}"
    read -r -p "Continue? [y/N] " confirm
    if [[ "$confirm" =~ ^[Yy]$ ]]; then
        rm -rf "$BUILD_DIR"
        success "Build directory removed"
    else
        info "Clean cancelled"
    fi
}

# ── Load to SD card ────────────────────────────────────────────────────────────
cmd_load() {
    local device="${1:-}"
    local target="${2:-preempt-rt}"
    local force="${3:-}"

    [[ -z "$device" ]] && die "Usage: ./cclrte.sh load <device> [preempt-rt|xenomai] [--force]
  Example: ./cclrte.sh load /dev/sdb preempt-rt
  Example: ./cclrte.sh load /dev/sdb xenomai"

    # Locate image based on build target
    local image_file
    case "$target" in
        preempt-rt|rpi4)
            image_file=$(find "${BUILD_DIR}/tmp/deploy/images/rpi4-cclrte" \
                -name "cclrte-image*.rpi-sdimg" 2>/dev/null | head -1) ;;
        xenomai)
            image_file=$(find "${BUILD_DIR}/tmp/deploy/images/rpi4-cclrte-xenomai" \
                -name "cclrte-xenomai-image*.rpi-sdimg" 2>/dev/null | head -1) ;;
        *)
            die "Unknown target: $target (use: preempt-rt | xenomai)" ;;
    esac

    [[ -z "$image_file" ]] && die "No image found for target '$target'. Run: ./cclrte.sh build $target"
    [[ ! -b "$device" ]]   && die "Device not found: $device"

    # Safety check — refuse to overwrite /dev/sda unless --force
    if [[ "$device" == "/dev/sda" && "$force" != "--force" ]]; then
        die "/dev/sda is likely your system disk. Use --force to override, or specify a different device."
    fi

    local image_size
    image_size=$(du -h "$image_file" | cut -f1)

    echo ""
    warn "About to write to ${device}"
    info "  Image  : $(basename "$image_file") (${image_size})"
    info "  Target : $target"
    info "  Device : $device"
    echo ""
    lsblk "$device" 2>/dev/null || true
    echo ""
    warn "ALL DATA ON ${device} WILL BE LOST"
    read -r -p "Type 'yes' to confirm: " confirm
    [[ "$confirm" != "yes" ]] && { info "Aborted"; exit 0; }

    # Unmount any mounted partitions
    mount | grep "^${device}" | awk '{print $1}' | xargs -r umount 2>/dev/null || true

    info "Writing image to ${device}..."
    if command -v pv &>/dev/null; then
        pv "$image_file" | dd of="$device" bs=4M conv=fsync
    else
        dd if="$image_file" of="$device" bs=4M conv=fsync status=progress
    fi

    sync
    success "Image written to ${device}"
    echo ""
    info "Next steps:"
    info "  1. Insert SD card into Raspberry Pi 4"
    info "  2. Connect eth0 to your PC (static IP 192.168.1.100)"
    info "  3. Power on — wait ~90 seconds for first boot"
    info "  4. SSH: ssh root@<wlan0-ip>"
    info "  5. Install CODESYS runtime: /usr/sbin/install-codesys-runtime.sh <package.deb>"
    info "  6. Open CODESYS IDE -> Gateway -> 192.168.1.100:1217"
}

# ── QEMU interactive ──────────────────────────────────────────────────────────
cmd_qemu() {
    local qemu_image
    qemu_image=$(find "${BUILD_DIR}/tmp/deploy/images/qemux86-64" -name "*.ext4" 2>/dev/null | head -1)
    [[ -z "$qemu_image" ]] && die "QEMU image not found. Run: ./cclrte.sh build qemu"

    local kernel
    kernel=$(find "${BUILD_DIR}/tmp/deploy/images/qemux86-64" -name "bzImage" 2>/dev/null | head -1)

    info "Launching QEMU — CCLRTE image"
    info "Login: root (no password)"
    info "Press Ctrl+A X to exit"
    echo ""

    qemu-system-x86_64 \
        -kernel "$kernel" \
        -drive  "file=${qemu_image},if=virtio,format=raw" \
        -append "root=/dev/vda console=ttyS0,115200 threadirqs preempt=full rw" \
        -nographic \
        -m 512M \
        -smp 4 \
        -net nic,model=virtio \
        -net user,hostfwd=tcp::2222-:22,hostfwd=tcp::8080-:8080
}

# ── Help ──────────────────────────────────────────────────────────────────────
cmd_help() {
    echo -e "
${BOLD}CCLRTE — CODESYS Control Linux RTE${NC}
Yocto-based hard real-time PLC image for Raspberry Pi 4

${BOLD}Usage:${NC}
  ${CYAN}./cclrte.sh build [target]${NC}        Build Yocto image
  ${CYAN}./cclrte.sh test${NC}                   Run unit tests + QEMU boot test
  ${CYAN}./cclrte.sh clean${NC}                  Remove build directory
  ${CYAN}./cclrte.sh load <dev> [target]${NC}   Flash image to SD card
  ${CYAN}./cclrte.sh qemu${NC}                   Boot QEMU image interactively
  ${CYAN}./cclrte.sh help${NC}                   Show this message

${BOLD}Build targets:${NC}
  ${GREEN}preempt-rt${NC}   Raspberry Pi 4 with PREEMPT_RT (default)
                  Cycle time: 500 us reliable
  ${GREEN}xenomai${NC}      Raspberry Pi 4 with Xenomai Cobalt
                  Cycle time: 250 us reliable (2-15 us worst-case latency)
  ${GREEN}qemu${NC}         QEMU x86-64 minimal image for CI testing

${BOLD}Examples:${NC}
  ./cclrte.sh build                        # PREEMPT_RT (default)
  ./cclrte.sh build xenomai               # Xenomai Cobalt
  ./cclrte.sh load /dev/sdb               # Flash PREEMPT_RT to SD
  ./cclrte.sh load /dev/sdb xenomai       # Flash Xenomai to SD
  ./cclrte.sh load /dev/sda --force       # Override safety check

${BOLD}First time:${NC}
  cp config/site.conf.sample config/site.conf
  # Edit config/site.conf (WiFi, SSH key, eth0 IP)
  ./cclrte.sh build

${BOLD}Requirements:${NC}
  kas or docker, python3, qemu-system-x86_64 (for qemu command)
  pv (optional, for progress bar during SD card write)
"
}

# ── Dispatch ──────────────────────────────────────────────────────────────────
cd "$SCRIPT_DIR"

case "${1:-help}" in
    build)  cmd_build  "${2:-preempt-rt}" ;;
    test)   cmd_test ;;
    clean)  cmd_clean ;;
    load)   cmd_load "${2:-}" "${3:-preempt-rt}" "${4:-}" ;;
    qemu)   cmd_qemu ;;
    help|-h|--help) cmd_help ;;
    *) error "Unknown command: $1"; cmd_help; exit 1 ;;
esac
