#!/bin/bash
# CCLRTE — CODESYS Control Linux RTE
# Author: Vasu Padsumbia
# Main management script: build / test / clean / load / qemu
# Usage: ./cclrte.sh <command> [options]

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BUILD_DIR="${SCRIPT_DIR}/build"
VENV_DIR="${SCRIPT_DIR}/venv"
KAS_DIR="${SCRIPT_DIR}/kas"
LOGS_DIR="${SCRIPT_DIR}/logs"
mkdir -p "${LOGS_DIR}"

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
    # Prefer venv kas (always installed by setup_venv)
    if [[ -x "${VENV_DIR}/bin/kas" ]]; then
        echo "${VENV_DIR}/bin/kas"
    elif command -v kas &>/dev/null; then
        echo "kas"
    elif [[ -x "${SCRIPT_DIR}/kas-container" ]]; then
        echo "${SCRIPT_DIR}/kas-container"
    else
        die "kas not found. Run: python3 -m venv venv && venv/bin/pip install kas"
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
        preempt-rt) kas_file="${KAS_DIR}/rpi5-64.yml" ;;
        xenomai)    kas_file="${KAS_DIR}/rpi5-xenomai.yml" ;;
        qemu)       kas_file="${KAS_DIR}/qemu-x86-64.yml" ;;
        *) die "Unknown build target: $target (use: preempt-rt | xenomai | qemu)" ;;
    esac

    local kas_runner
    kas_runner=$(detect_kas)

    local log_file="${LOGS_DIR}/build-${target}.log"

    info "Build target : ${BOLD}${target}${NC}"
    info "KAS config   : ${kas_file}"
    info "KAS runner   : ${kas_runner}"
    info "Build log    : ${log_file}"
    echo ""

    $kas_runner build "$kas_file" 2>&1 | tee "${log_file}"

    success "Build complete: $target"
    info "Full build log: ${log_file}"
    echo ""
    info "Image location:"
    case "$target" in
        preempt-rt)
            find "${BUILD_DIR}/tmp/deploy/images/rpi5-cclrte" -name "*.rpi-sdimg" 2>/dev/null || true ;;
        xenomai)
            find "${BUILD_DIR}/tmp/deploy/images/rpi5-cclrte-xenomai" -name "*.rpi-sdimg" 2>/dev/null || true ;;
        qemu)
            find "${BUILD_DIR}/tmp/deploy/images/qemux86-64" -name "*.ext4" 2>/dev/null || true ;;
    esac

    echo ""
    cmd_verify "$target"
}

# ── Test ──────────────────────────────────────────────────────────────────────
cmd_test() {
    info "Running CCLRTE test suite"
    activate_venv

    local test_log="${LOGS_DIR}/test-$(date +%Y%m%d-%H%M%S).log"
    info "Test log: ${test_log}"
    echo ""

    info "── Unit tests ─────────────────────────────────────────"
    # Unset PYTHONPATH to prevent ROS2 (or other system packages) from injecting
    # their pytest plugins into the venv environment.
    PYTHONPATH="" python3 -m pytest "${SCRIPT_DIR}/tests/unit/" -v --tb=short 2>&1 | tee "${test_log}" || {
        error "Unit tests failed — see ${test_log}"
        exit 1
    }

    echo ""
    info "── QEMU boot test ─────────────────────────────────────"
    local qemu_image
    qemu_image=$(find "${BUILD_DIR}/tmp/deploy/images/qemux86-64" \
        -name "cclrte-image-qemu*.wic" -o -name "cclrte-image-qemu*.ext4" \
        2>/dev/null | head -1)
    if [[ -n "$qemu_image" ]]; then
        bash "${SCRIPT_DIR}/tests/qemu/run_qemu_test.sh" 2>&1 | tee -a "${test_log}"
    else
        warn "QEMU image not found — run './cclrte.sh build qemu' first to enable boot tests"
    fi

    success "All tests passed — log: ${test_log}"
}

# ── Clean helpers ─────────────────────────────────────────────────────────────
_rm() {
    local target="$1"
    if [[ ! -e "$target" ]]; then
        info "Already clean: $(basename "$target")"
        return
    fi
    local size
    size=$(du -sh "$target" 2>/dev/null | cut -f1 || echo "?")
    info "Removing: $target  [${size}]"
    rm -rf "$target"
}

# ── Clean ─────────────────────────────────────────────────────────────────────
cmd_clean() {
    local scope="${1:-build}"
    local _target="${2:-preempt-rt}"

    case "$scope" in
        recipes)
            # Targeted sstate clean — only meta-cclrte recipes, leaves upstream cache intact.
            # Run this after editing recipes/files in layers/meta-cclrte/ to force a rebuild
            # of just those packages without discarding the full sstate cache.
            local kas_file
            case "$_target" in
                preempt-rt) kas_file="${KAS_DIR}/rpi5-64.yml" ;;
                xenomai)    kas_file="${KAS_DIR}/rpi5-xenomai.yml" ;;
                qemu)       kas_file="${KAS_DIR}/qemu-x86-64.yml" ;;
                *) die "Unknown target: $_target (use: preempt-rt | xenomai | qemu)" ;;
            esac

            # Collect recipe names from meta-cclrte — strip version suffix and extension.
            # e.g. cclrte-network_1.0.bb → cclrte-network
            #      watchdog_%.bbappend   → watchdog
            #      cclrte-image.bb      → cclrte-image
            local recipes=()
            while IFS= read -r fname; do
                local rname="${fname%%_*}"   # strip _1.0.bb or _%.bbappend
                rname="${rname%.bbappend}"   # strip .bbappend (for files without _)
                rname="${rname%.bb}"         # strip .bb (for files without _)
                [[ -n "$rname" ]] && recipes+=("$rname")
            done < <(find "${SCRIPT_DIR}/layers/meta-cclrte" \
                         \( -name "*.bb" -o -name "*.bbappend" \) \
                         ! -path "*/images/*" \
                         -printf "%f\n" 2>/dev/null | sort -u)

            # Deduplicate into unique_recipes array
            local unique_recipes=()
            while IFS= read -r r; do
                unique_recipes+=("$r")
            done < <(printf '%s\n' "${recipes[@]}" | sort -u)

            # Always include the image recipes explicitly
            case "$_target" in
                preempt-rt) unique_recipes+=("cclrte-image") ;;
                xenomai)    unique_recipes+=("cclrte-xenomai-image" "cclrte-image") ;;
                qemu)       unique_recipes+=("cclrte-image-qemu") ;;
            esac

            info "Cleaning sstate for ${#unique_recipes[@]} meta-cclrte recipes (target: $_target):"
            printf '  %s\n' "${unique_recipes[@]}"
            echo ""

            local kas_runner
            kas_runner=$(detect_kas)
            # kas shell -c "cmd" passes cmd to bitbake inside the kas environment
            $kas_runner shell "$kas_file" -c \
                "bitbake -c cleansstate ${unique_recipes[*]}" 2>&1 | tee "${LOGS_DIR}/clean-recipes-${_target}.log"

            success "Recipe sstate cleared — next build will recompile all meta-cclrte packages"
            ;;
        build)
            warn "Remove build/ only (keeps downloads + sstate-cache): ${BUILD_DIR}"
            read -r -p "Continue? [y/N] " confirm
            [[ "$confirm" =~ ^[Yy]$ ]] || { info "Cancelled"; return; }
            _rm "$BUILD_DIR"
            _rm "${SCRIPT_DIR}/logs"
            _rm "${SCRIPT_DIR}/__pycache__"
            find "${SCRIPT_DIR}" -name "*.pyc" -delete 2>/dev/null || true
            success "Build clean complete"
            ;;
        sstate)
            warn "Remove sstate-cache/ (forces full recompile, keeps downloads): ${SCRIPT_DIR}/sstate-cache"
            read -r -p "Continue? [y/N] " confirm
            [[ "$confirm" =~ ^[Yy]$ ]] || { info "Cancelled"; return; }
            _rm "${SCRIPT_DIR}/sstate-cache"
            success "sstate cache removed"
            ;;
        downloads)
            warn "Remove downloads/ (forces re-fetch of all sources): ${SCRIPT_DIR}/downloads"
            read -r -p "Continue? [y/N] " confirm
            [[ "$confirm" =~ ^[Yy]$ ]] || { info "Cancelled"; return; }
            _rm "${SCRIPT_DIR}/downloads"
            success "Downloads removed"
            ;;
        all)
            warn "Remove EVERYTHING: build/ + sstate-cache/ + downloads/ + logs/ (~10+ GB)"
            read -r -p "Type 'yes' to confirm: " confirm
            [[ "$confirm" == "yes" ]] || { info "Cancelled"; return; }
            # Delete large dirs in parallel
            _rm "$BUILD_DIR"           &
            _rm "${SCRIPT_DIR}/sstate-cache" &
            _rm "${SCRIPT_DIR}/downloads"    &
            wait
            # Small dirs — no need to background
            _rm "${SCRIPT_DIR}/logs"
            _rm "${SCRIPT_DIR}/__pycache__"
            find "${SCRIPT_DIR}" -name "*.pyc" -delete 2>/dev/null || true
            find "${SCRIPT_DIR}" -name ".kas_lock" -delete 2>/dev/null || true
            success "Full clean complete"
            ;;
        *)
            die "Unknown clean scope: $scope
Usage: ./cclrte.sh clean [recipes|build|sstate|downloads|all] [target]
  recipes     Invalidate sstate for meta-cclrte recipes only (fast, recommended after recipe edits)
  build       Remove build/ + logs/ (default)
  sstate      Remove sstate-cache/ (forces full recompile of everything)
  downloads   Remove downloads/ (forces re-fetch of all sources)
  all         Remove everything in parallel"
            ;;
    esac
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
        preempt-rt)
            image_file=$(find "${BUILD_DIR}/tmp/deploy/images/rpi5-cclrte" \
                -name "cclrte-image*.rpi-sdimg" 2>/dev/null | head -1) ;;
        xenomai)
            image_file=$(find "${BUILD_DIR}/tmp/deploy/images/rpi5-cclrte-xenomai" \
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

    # ── Copy site.conf to boot partition ──────────────────────────────────────
    local site_conf="${SCRIPT_DIR}/config/site.conf"
    # Partition suffix: /dev/sdb → /dev/sdb1, /dev/mmcblk0 → /dev/mmcblk0p1
    local boot_part
    if [[ "$device" =~ "mmcblk" ]] || [[ "$device" =~ "nvme" ]]; then
        boot_part="${device}p1"
    else
        boot_part="${device}1"
    fi
    if [[ -f "$site_conf" ]]; then
        info "Copying site.conf to boot partition (${boot_part})..."
        local mnt
        mnt=$(mktemp -d)
        if mount "${boot_part}" "$mnt" 2>/dev/null; then
            cp "$site_conf" "${mnt}/site.conf"
            sync
            umount "$mnt"
            rmdir "$mnt"
            success "site.conf copied to /boot/site.conf — WiFi + eth0 will be configured on first boot"
        else
            rmdir "$mnt"
            warn "Could not mount ${boot_part} — copy site.conf manually:"
            warn "  mount ${boot_part} /mnt && cp config/site.conf /mnt/site.conf && umount /mnt"
        fi
    else
        warn "config/site.conf not found — network will use image defaults (eth0 192.168.2.100)"
        warn "Create it from: cp config/site.conf.sample config/site.conf"
    fi

    echo ""
    info "Next steps:"
    info "  1. Insert SD card into Raspberry Pi 5"
    info "  2. Connect Ethernet to your PC — set PC to 192.168.2.x/24"
    info "  3. Power on — wait ~60 seconds for first boot"
    info "  4. SSH: ssh root@192.168.2.100  password: cclrte"
    info "  5. WiFi IP appears in: journalctl -u systemd-networkd | grep wlan0"
    info "  6. IDE installs runtime, gateway auto-configured for RT (CPU3, SCHED_FIFO 80)"
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

# ── Image verification ────────────────────────────────────────────────────────
cmd_verify() {
    local target="${1:-preempt-rt}"
    local _pass=0 _fail=0

    _vcheck() {
        local desc="$1" result="$2" detail="${3:-}"
        if [[ "$result" == "PASS" ]]; then
            echo -e "  ${GREEN}✔${NC}  $desc${detail:+  ${CYAN}($detail)${NC}}"
            ((_pass++))
        else
            echo -e "  ${RED}✘${NC}  $desc${detail:+  ${YELLOW}→ $detail${NC}}"
            ((_fail++))
        fi
    }

    # ── Locate image ──────────────────────────────────────────────────────────
    local image_file
    case "$target" in
        preempt-rt)
            image_file=$(find "${BUILD_DIR}/tmp/deploy/images/rpi5-cclrte" \
                -name "cclrte-image*.rpi-sdimg" 2>/dev/null | sort | tail -1) ;;
        xenomai)
            image_file=$(find "${BUILD_DIR}/tmp/deploy/images/rpi5-cclrte-xenomai" \
                \( -name "cclrte-xenomai-image*.rpi-sdimg" -o -name "cclrte-image*.rpi-sdimg" \) \
                2>/dev/null | sort | tail -1) ;;
        qemu)
            image_file=$(find "${BUILD_DIR}/tmp/deploy/images/qemux86-64" \
                \( -name "cclrte-image-qemu*.wic" -o -name "cclrte-image-qemu*.ext4" \) \
                2>/dev/null | sort | tail -1) ;;
        *) die "verify: unknown target '$target'" ;;
    esac

    info "── Image verification: ${BOLD}${target}${NC} ─────────────────────────────"

    # Check 1 — image exists
    if [[ -n "$image_file" && -f "$image_file" ]]; then
        _vcheck "Image file present" PASS "$(basename "$image_file")"
    else
        _vcheck "Image file present" FAIL "not found — run './cclrte.sh build $target' first"
        echo ""
        error "Verification aborted: no image to inspect"
        return 1
    fi

    # Check 2 — minimum size
    local size_bytes size_mb min_mb
    size_bytes=$(stat -c%s "$image_file" 2>/dev/null || echo 0)
    size_mb=$(( size_bytes / 1024 / 1024 ))
    min_mb=150; [[ "$target" == "qemu" ]] && min_mb=50
    if [[ "$size_mb" -ge "$min_mb" ]]; then
        _vcheck "Image size" PASS "${size_mb} MB"
    else
        _vcheck "Image size" FAIL "${size_mb} MB < ${min_mb} MB minimum — build may be incomplete"
    fi

    # ── RPi-specific checks ───────────────────────────────────────────────────
    if [[ "$target" != "qemu" ]]; then

        # Check 3 — valid partition table
        local fdisk_out
        fdisk_out=$(fdisk -l "$image_file" 2>/dev/null)
        # partitions listed as <file>1 <file>2 (no 'p' for raw images)
        local part_count
        part_count=$(echo "$fdisk_out" | grep -cE "^${image_file}p?[0-9]" 2>/dev/null || echo 0)
        if [[ "$part_count" -ge 2 ]]; then
            _vcheck "Partition table (MBR)" PASS "${part_count} partitions"
        else
            _vcheck "Partition table (MBR)" FAIL "expected ≥2 partitions, found ${part_count}"
        fi

        # Check 4 — FAT boot + Linux root
        local has_fat has_linux
        has_fat=$(echo "$fdisk_out"  | grep -cEi "FAT|W95|VFAT" || echo 0)
        has_linux=$(echo "$fdisk_out" | grep -c "Linux"           || echo 0)
        if [[ "$has_fat" -ge 1 && "$has_linux" -ge 1 ]]; then
            _vcheck "Partition types" PASS "FAT boot + Linux root"
        else
            _vcheck "Partition types" FAIL "missing FAT or Linux partition"
        fi

        # Checks 5–10 require loop-mounting — need losetup (usually requires root)
        local loop_dev
        loop_dev=$(losetup -P --find --show "$image_file" 2>/dev/null || echo "")
        if [[ -z "$loop_dev" ]]; then
            warn "  losetup unavailable (re-run as root for filesystem content checks)"
        else
            local mnt_boot mnt_root
            mnt_boot=$(mktemp -d)
            mnt_root=$(mktemp -d)

            # ── Boot partition ────────────────────────────────────────────────
            if mount -t vfat "${loop_dev}p1" "$mnt_boot" 2>/dev/null; then

                # Check 5 — kernel image
                if ls "${mnt_boot}"/kernel*.img "${mnt_boot}"/Image 2>/dev/null | head -1 | grep -q .; then
                    _vcheck "Boot: kernel image" PASS \
                        "$(ls "${mnt_boot}"/kernel*.img "${mnt_boot}"/Image 2>/dev/null | xargs -I{} basename {} | tr '\n' ' ')"
                else
                    _vcheck "Boot: kernel image" FAIL "kernel8.img / Image not found"
                fi

                # Check 6 — config.txt present and has cclrte markers
                if [[ -f "${mnt_boot}/config.txt" ]]; then
                    if grep -q "force_turbo" "${mnt_boot}/config.txt" 2>/dev/null; then
                        _vcheck "Boot: config.txt" PASS "force_turbo set (CPU locked at 2.4 GHz)"
                    else
                        _vcheck "Boot: config.txt" FAIL "present but missing force_turbo RT tuning"
                    fi
                else
                    _vcheck "Boot: config.txt" FAIL "not found in boot partition"
                fi

                # Check 7 — RPi5 firmware blobs
                if ls "${mnt_boot}"/start*.elf 2>/dev/null | grep -q .; then
                    _vcheck "Boot: VideoCore firmware" PASS \
                        "$(ls "${mnt_boot}"/start*.elf 2>/dev/null | xargs -I{} basename {} | tr '\n' ' ')"
                else
                    _vcheck "Boot: VideoCore firmware" FAIL "start4.elf / start.elf not found"
                fi

                umount "$mnt_boot" 2>/dev/null
            else
                _vcheck "Boot partition mount" FAIL "could not mount ${loop_dev}p1 (vfat)"
            fi

            # ── Root partition ────────────────────────────────────────────────
            if mount "${loop_dev}p2" "$mnt_root" 2>/dev/null; then

                # Check 8 — systemd init
                if [[ -e "${mnt_root}/sbin/init" || \
                      -f "${mnt_root}/lib/systemd/systemd" ]]; then
                    _vcheck "Root: systemd/init" PASS
                else
                    _vcheck "Root: systemd/init" FAIL "/sbin/init and /lib/systemd/systemd absent"
                fi

                # Check 9 — CODESYS staging dirs (codesys-control recipe)
                if [[ -d "${mnt_root}/opt/codesys" ]]; then
                    _vcheck "Root: /opt/codesys" PASS "staging dirs present"
                else
                    _vcheck "Root: /opt/codesys" FAIL "missing — codesys-control not installed"
                fi

                # Check 10 — RT tooling
                local cyclic_bin
                cyclic_bin=$(find "${mnt_root}/usr" -name "cyclictest" 2>/dev/null | head -1)
                if [[ -n "$cyclic_bin" ]]; then
                    _vcheck "Root: cyclictest" PASS
                else
                    _vcheck "Root: cyclictest" FAIL "rt-tests not in image"
                fi

                # Check 11 — IgH EtherCAT
                local ec_bin
                ec_bin=$(find "${mnt_root}/usr/sbin" "${mnt_root}/sbin" \
                    -name "ethercatctl" 2>/dev/null | head -1)
                if [[ -n "$ec_bin" ]]; then
                    _vcheck "Root: ethercatctl" PASS "igh-ethercat installed"
                else
                    _vcheck "Root: ethercatctl" FAIL "igh-ethercat not in image"
                fi

                # Check 12 — WebUI service
                local webui_svc
                webui_svc=$(find "${mnt_root}/lib/systemd/system" \
                    "${mnt_root}/usr/lib/systemd/system" \
                    -name "plc-webui.service" 2>/dev/null | head -1)
                if [[ -n "$webui_svc" ]]; then
                    _vcheck "Root: plc-webui.service" PASS
                else
                    _vcheck "Root: plc-webui.service" FAIL "WebUI service unit not found"
                fi

                umount "$mnt_root" 2>/dev/null

                # Check 13 — ext4 filesystem integrity
                local fsck_exit
                e2fsck -n "${loop_dev}p2" &>/dev/null
                fsck_exit=$?
                if [[ "$fsck_exit" -le 1 ]]; then
                    _vcheck "Root: ext4 integrity (e2fsck)" PASS
                else
                    _vcheck "Root: ext4 integrity (e2fsck)" FAIL "exit code $fsck_exit — filesystem errors"
                fi
            else
                _vcheck "Root partition mount" FAIL "could not mount ${loop_dev}p2 (ext4)"
            fi

            rmdir "$mnt_boot" "$mnt_root" 2>/dev/null
            losetup -d "$loop_dev" 2>/dev/null
        fi

    # ── QEMU-specific checks ──────────────────────────────────────────────────
    else
        # Check 3 — companion kernel
        local kernel
        kernel=$(find "${BUILD_DIR}/tmp/deploy/images/qemux86-64" \
            -name "bzImage" 2>/dev/null | head -1)
        if [[ -n "$kernel" ]]; then
            _vcheck "QEMU kernel (bzImage)" PASS "$(basename "$kernel")"
        else
            _vcheck "QEMU kernel (bzImage)" FAIL "bzImage not found alongside image"
        fi

        # Check 4 — filesystem integrity
        local fsck_exit
        e2fsck -n "$image_file" &>/dev/null
        fsck_exit=$?
        if [[ "$fsck_exit" -le 1 ]]; then
            _vcheck "Filesystem integrity (e2fsck)" PASS
        else
            _vcheck "Filesystem integrity (e2fsck)" FAIL "exit code $fsck_exit"
        fi
    fi

    # ── Summary ───────────────────────────────────────────────────────────────
    echo ""
    local _total=$(( _pass + _fail ))
    if [[ "$_fail" -eq 0 ]]; then
        success "Verification: ${_pass}/${_total} checks passed — image is ${BOLD}BOOTABLE${NC} for ${target}"
    else
        error   "Verification: ${_fail}/${_total} checks FAILED — image may not boot on ${target}"
        return 1
    fi
}

# ── Help ──────────────────────────────────────────────────────────────────────
cmd_help() {
    echo -e "
${BOLD}CCLRTE — CODESYS Control Linux RTE${NC}
Yocto-based hard real-time PLC image for Raspberry Pi 5

${BOLD}Usage:${NC}
  ${CYAN}./cclrte.sh build [target]${NC}                       Build Yocto image (runs verify automatically)
  ${CYAN}./cclrte.sh verify [target]${NC}                      Verify image is correctly formed + bootable
  ${CYAN}./cclrte.sh test${NC}                                  Run unit tests + QEMU boot test
  ${CYAN}./cclrte.sh clean recipes [target]${NC}               Invalidate sstate for meta-cclrte recipes only (fast)
  ${CYAN}./cclrte.sh clean [build|sstate|downloads|all]${NC}   Clean build artifacts
  ${CYAN}./cclrte.sh load <dev> [target]${NC}                  Flash image to SD card
  ${CYAN}./cclrte.sh qemu${NC}                                  Boot QEMU image interactively
  ${CYAN}./cclrte.sh help${NC}                                  Show this message

${BOLD}Build targets:${NC}
  ${GREEN}preempt-rt${NC}   RPi5 2GB with PREEMPT_RT (default)
                BCM2712 / Cortex-A76 @ 2.4 GHz (force_turbo), cycle time 500 us
  ${GREEN}xenomai${NC}      RPi5 2GB with Xenomai Cobalt hard-RT
                Requires Dovetail patches for kernel 6.6 + BCM2712
  ${GREEN}qemu${NC}         QEMU x86-64 minimal image for CI testing

${BOLD}Examples:${NC}
  ./cclrte.sh build                    # PREEMPT_RT RPi5 (default)
  ./cclrte.sh build xenomai           # Xenomai Cobalt RPi5
  ./cclrte.sh load /dev/sdb           # Flash PREEMPT_RT to SD
  ./cclrte.sh load /dev/sdb xenomai   # Flash Xenomai to SD
  ./cclrte.sh load /dev/sda --force   # Override safety check

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
    verify) cmd_verify "${2:-preempt-rt}" ;;
    test)   cmd_test ;;
    clean)  cmd_clean "${2:-build}" "${3:-preempt-rt}" ;;
    load)   cmd_load "${2:-}" "${3:-preempt-rt}" "${4:-}" ;;
    qemu)   cmd_qemu ;;
    help|-h|--help) cmd_help ;;
    *) error "Unknown command: $1"; cmd_help; exit 1 ;;
esac
