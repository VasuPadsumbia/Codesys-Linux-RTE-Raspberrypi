#!/bin/bash
# CCLRTE — CODESYS Control Linux RTE
# Author: Vasu Padsumbia
# Main management script: build / test / clean / load / qemu
# Usage: ./cclrte.sh <command> [options]

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BUILD_DIR="${KAS_BUILD_DIR:-${SCRIPT_DIR}/build}"
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

# ── site.conf build-var loader ────────────────────────────────────────────────
# Sources only CODESYS_ prefixed vars from config/site.conf so WiFi passwords
# etc. are not exported into kas/bitbake child processes.
load_build_vars() {
    local site_conf="${SCRIPT_DIR}/config/site.conf"
    [[ -f "$site_conf" ]] || return 0
    while IFS= read -r line; do
        line="${line%%#*}"
        [[ -z "${line//[[:space:]]/}" ]] && continue
        [[ "$line" =~ ^(CODESYS_|CODEMETER_)[A-Z_]+=.* ]] || continue
        line="${line//$'\r'/}"   # strip CR in case site.conf has CRLF endings
        export "${line//\"/}" 2>/dev/null || true
    done < "$site_conf"
}

# Write package vars as a plain bitbake .conf file included by base.yml local_conf_header.
# Avoids YAML generation entirely — bitbake include is simpler and always reliable.
write_pkg_conf() {
    local conf="${KAS_DIR}/.cclrte-packages.conf"
    printf 'CODESYS_DEB   = "%s"\n' "${CODESYS_DEB:-codesyscontrol_linuxarm64_4.20.0.0_arm64.deb}" > "$conf"
    printf 'CODESYS_IPK   = "%s"\n' "${CODESYS_IPK:-codesyscontrol_linuxarm64_4.20.0.0_arm64.ipk}" >> "$conf"
    printf 'CODEMETER_DEB = "%s"\n' "${CODEMETER_DEB:-codemeter-lite_8.40.7131.502_arm64.deb}"      >> "$conf"
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

    ensure_site_conf
    load_build_vars
    write_pkg_conf

    info "Build target : ${BOLD}${target}${NC}"
    info "KAS config   : ${kas_file}"
    info "KAS runner   : ${kas_runner}"
    info "Build log    : ${log_file}"
    info "CODESYS_DEB  : ${CODESYS_DEB:-codesyscontrol_linuxarm64_4.20.0.0_arm64.deb}"
    info "CODEMETER_DEB: ${CODEMETER_DEB:-codemeter-lite_8.40.7131.502_arm64.deb}"
    echo ""

    $kas_runner build "$kas_file" 2>&1 | tee "${log_file}"

    success "Build complete: $target"
    info "Full build log: ${log_file}"
    echo ""

    copy_image_to_output "$target"

    echo ""
    cmd_verify "$target"
}

# ── Copy built image to data/output/ ──────────────────────────────────────────
copy_image_to_output() {
    local target="$1"
    local output_dir="${SCRIPT_DIR}/data/output"
    mkdir -p "$output_dir"

    local deploy_dir image_pattern
    case "$target" in
        preempt-rt)
            deploy_dir="${BUILD_DIR}/tmp/deploy/images/rpi5-cclrte"
            image_pattern="*.rpi-sdimg" ;;
        xenomai)
            deploy_dir="${BUILD_DIR}/tmp/deploy/images/rpi5-cclrte-xenomai"
            image_pattern="*.rpi-sdimg" ;;
        qemu)
            deploy_dir="${BUILD_DIR}/tmp/deploy/images/qemux86-64"
            image_pattern="*.ext4" ;;
    esac

    local image_file
    image_file=$(find "$deploy_dir" -name "$image_pattern" -not -type l 2>/dev/null | sort | tail -1)

    if [[ -z "$image_file" ]]; then
        warn "No image found in ${deploy_dir}"
        return
    fi

    local dest="${output_dir}/$(basename "$image_file")"
    info "Copying image to data/output/ ..."
    cp "$image_file" "$dest"
    success "Image: ${dest}"

    inject_site_conf "$dest"

    info "Flash: ./cclrte.sh load /dev/sdX ${target}"
}

# ── Ensure config/site.conf exists (copy from sample on first use) ────────────
ensure_site_conf() {
    local site_conf="${SCRIPT_DIR}/config/site.conf"
    local sample="${SCRIPT_DIR}/config/site.conf.sample"
    if [[ ! -f "$site_conf" && -f "$sample" ]]; then
        cp "$sample" "$site_conf"
        info "Created config/site.conf from sample — edit it before building"
    fi
}

# ── Inject site.conf into the boot FAT partition of the SD image ───────────────
# MERGES with any existing site.conf on the image — only updates keys present
# in config/site.conf, preserving any custom settings already on the SD card.
inject_site_conf() {
    local image="$1"
    local site_conf="${SCRIPT_DIR}/config/site.conf"

    [[ -f "$site_conf" ]] || { warn "site.conf not found — skipping injection"; return; }
    command -v mcopy &>/dev/null || { warn "mtools not installed — site.conf not injected"; return; }

    local start_sector
    start_sector=$(fdisk -lu "$image" 2>/dev/null | awk '/FAT|W95|vfat|type c|0xc/{print $2; exit}')
    [[ -z "$start_sector" ]] && start_sector=8192
    local byte_offset=$(( start_sector * 512 ))
    local marg="${image}@@${byte_offset}"

    # Read existing site.conf from image (may not exist on first flash)
    local existing_conf
    existing_conf=$(mtype -i "$marg" ::/site.conf 2>/dev/null || true)

    # Merge: start with existing, then overlay keys from config/site.conf
    local merged
    merged=$(python3 - "$site_conf" <<'PYEOF'
import sys, re

def parse(text):
    result = {}
    order = []
    for line in text.splitlines():
        m = re.match(r'^([A-Z_][A-Z0-9_]*)=(.*)', line)
        if m:
            key = m.group(1)
            if key not in result:
                order.append(key)
            result[key] = line   # preserve full line including quotes/comments
        else:
            order.append(('\x00', line))  # non-key lines (comments, blank)
    return result, order

# existing from stdin (may be empty), new from file arg
existing_text = sys.stdin.read()
new_text = open(sys.argv[1]).read()

existing, ex_order = parse(existing_text)
new_vals, _        = parse(new_text)

# Apply new values over existing
merged = dict(existing)
merged.update(new_vals)

# Output: preserve existing structure, add new keys at end
seen = set()
for item in ex_order:
    if isinstance(item, tuple):
        print(item[1])
    else:
        key = item
        seen.add(key)
        print(merged.get(key, existing.get(key, '')))

# Append keys that are new (not in existing at all)
for key, line in new_vals.items():
    if key not in seen and key not in existing:
        print(line)
PYEOF
<<< "$existing_conf")

    # Write merged result back to image
    local tmpfile
    tmpfile=$(mktemp /tmp/site-conf-XXXXXX.conf)
    echo "$merged" > "$tmpfile"
    mcopy -i "$marg" -o "$tmpfile" ::/site.conf 2>/dev/null && \
        success "site.conf merged into boot partition → WiFi/hostname auto-configure on first boot" || \
        warn "site.conf injection failed — copy manually to SD card boot partition"
    rm -f "$tmpfile"
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
    local target="preempt-rt"
    local force=""

    # Parse remaining args — target is the first non-flag arg; --force can appear anywhere
    shift || true
    for arg in "$@"; do
        case "$arg" in
            --force) force="--force" ;;
            preempt-rt|xenomai|qemu) target="$arg" ;;
            *) die "Unknown argument: $arg" ;;
        esac
    done

    [[ -z "$device" ]] && die "Usage: ./cclrte.sh load <device> [preempt-rt|xenomai] [--force]
  Example: ./cclrte.sh load /dev/sdb
  Example: ./cclrte.sh load /dev/sdb preempt-rt
  Example: ./cclrte.sh load /dev/sdb xenomai
  Example: ./cclrte.sh load /dev/sda preempt-rt --force"

    [[ "$target" == "qemu" ]] && die "QEMU images run in a VM and cannot be flashed to an SD card.
  To run QEMU: ./cclrte.sh qemu"

    # Locate image based on build target
    local image_file
    case "$target" in
        preempt-rt)
            image_file=$(find "${BUILD_DIR}/tmp/deploy/images/rpi5-cclrte" \
                -name "cclrte-image*.rpi-sdimg" 2>/dev/null | sort | tail -1) ;;
        xenomai)
            image_file=$(find "${BUILD_DIR}/tmp/deploy/images/rpi5-cclrte-xenomai" \
                -name "cclrte-xenomai-image*.rpi-sdimg" 2>/dev/null | sort | tail -1) ;;
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

                # Check 8 — cmdline.txt RT isolation params
                local cmdline_file="${mnt_boot}/cmdline.txt"
                if [[ -f "$cmdline_file" ]]; then
                    local cmdline_content
                    cmdline_content=$(cat "$cmdline_file" 2>/dev/null)
                    local cmd_ok=PASS cmd_detail=""
                    for param in "isolcpus=2,3" "nohz_full=2,3" "rcu_nocbs=2,3" "threadirqs"; do
                        if ! grep -q "$param" <<< "$cmdline_content"; then
                            cmd_ok=FAIL
                            cmd_detail="${cmd_detail}${param} missing; "
                        fi
                    done
                    if [[ "$target" == "preempt-rt" ]] && ! grep -q "preempt=full" <<< "$cmdline_content"; then
                        cmd_ok=FAIL
                        cmd_detail="${cmd_detail}preempt=full missing; "
                    fi
                    _vcheck "Boot: cmdline.txt RT params" "$cmd_ok" "${cmd_detail:-isolcpus nohz_full rcu_nocbs threadirqs all present}"
                else
                    _vcheck "Boot: cmdline.txt RT params" FAIL "cmdline.txt not found in boot partition"
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

                # Check 11 — IgH EtherCAT userspace tools
                local ec_bin
                ec_bin=$(find "${mnt_root}/usr/sbin" "${mnt_root}/sbin" \
                    -name "ethercatctl" 2>/dev/null | head -1)
                if [[ -n "$ec_bin" ]]; then
                    _vcheck "Root: ethercatctl" PASS "igh-ethercat installed"
                else
                    _vcheck "Root: ethercatctl" FAIL "igh-ethercat not in image"
                fi

                # Check 11b — IgH EtherCAT kernel modules (ec_master + ec_generic)
                local ec_master_ko ec_generic_ko
                ec_master_ko=$(find "${mnt_root}/lib/modules" \
                    -name "ec_master.ko" -o -name "ec_master.ko.gz" -o -name "ec_master.ko.xz" \
                    2>/dev/null | head -1)
                ec_generic_ko=$(find "${mnt_root}/lib/modules" \
                    -name "ec_generic.ko" -o -name "ec_generic.ko.gz" -o -name "ec_generic.ko.xz" \
                    2>/dev/null | head -1)
                if [[ -n "$ec_master_ko" && -n "$ec_generic_ko" ]]; then
                    _vcheck "Root: ec_master + ec_generic .ko" PASS \
                        "$(basename "$ec_master_ko"), $(basename "$ec_generic_ko")"
                elif [[ -n "$ec_master_ko" ]]; then
                    _vcheck "Root: ec_master + ec_generic .ko" FAIL \
                        "ec_master found but ec_generic missing — ethercatctl start will fail"
                else
                    _vcheck "Root: ec_master + ec_generic .ko" FAIL \
                        "neither module found — modprobe will fail at boot (rebuild igh-ethercat)"
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

                # Check 13 — WebUI timesync template
                if [[ -f "${mnt_root}/opt/cclrte/webui/templates/timesync.html" ]]; then
                    _vcheck "Root: WebUI timesync.html" PASS
                else
                    _vcheck "Root: WebUI timesync.html" FAIL "missing — timesync page will 500; rebuild plc-webui"
                fi

                # Check 14 — rt-setup.service (system-wide RT init before EtherCAT/CODESYS)
                local rt_svc
                rt_svc=$(find "${mnt_root}/lib/systemd/system" \
                    "${mnt_root}/usr/lib/systemd/system" \
                    -name "rt-setup.service" 2>/dev/null | head -1)
                if [[ -n "$rt_svc" ]]; then
                    _vcheck "Root: rt-setup.service" PASS
                else
                    _vcheck "Root: rt-setup.service" FAIL "missing — IRQ affinity and RT sysctl will not be applied at boot"
                fi

                # Check 15 — CODESYS RT drop-in (CPU3, SCHED_FIFO 80)
                if [[ -f "${mnt_root}/usr/lib/systemd/system/codesyscontrol.service.d/rt-override.conf" || \
                      -f "${mnt_root}/lib/systemd/system/codesyscontrol.service.d/rt-override.conf" ]]; then
                    _vcheck "Root: CODESYS rt-override.conf" PASS "CPUAffinity=3 SCHED_FIFO 80 drop-in present"
                else
                    _vcheck "Root: CODESYS rt-override.conf" FAIL "missing — CODESYS will run on all CPUs without RT priority"
                fi

                # Check 16 — chrony conf.d with unlimited makestep (large clock offsets)
                local chrony_cclrte="${mnt_root}/etc/chrony/conf.d/10-cclrte.conf"
                if [[ -f "$chrony_cclrte" ]]; then
                    if grep -q "makestep.*-1" "$chrony_cclrte" 2>/dev/null; then
                        _vcheck "Root: chrony makestep unlimited" PASS "makestep 1.0 -1 set — large offsets will be corrected"
                    else
                        _vcheck "Root: chrony makestep unlimited" FAIL "makestep -1 not found in 10-cclrte.conf — clock may never sync after long power-off"
                    fi
                else
                    _vcheck "Root: chrony conf.d/10-cclrte.conf" FAIL "missing — no Cloudflare/Google NTP servers configured"
                fi

                # Check 17 — eth0.network has no Gateway (prevents eth0 stealing default route)
                local eth0_net="${mnt_root}/etc/systemd/network/10-eth0.network"
                if [[ -f "$eth0_net" ]]; then
                    if grep -qE "^Gateway=" "$eth0_net" 2>/dev/null; then
                        _vcheck "Root: eth0 no-gateway" FAIL "Gateway= found in 10-eth0.network — eth0 will steal default route and break NTP"
                    else
                        _vcheck "Root: eth0 no-gateway" PASS "no Gateway in eth0 config — wlan0 owns default route"
                    fi
                else
                    _vcheck "Root: eth0 no-gateway" FAIL "10-eth0.network not found"
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
  ${GREEN}preempt-rt${NC}   RPi5 2GB with PREEMPT_RT — ${BOLD}production-ready, use this${NC}
                BCM2712 / Cortex-A76 @ 2.4 GHz (force_turbo), cycle time 500 us
                All features: CODESYS, WebUI, NTP, EtherCAT, Watchdog
  ${YELLOW}xenomai${NC}      RPi5 2GB with Dovetail/Cobalt kernel — ${YELLOW}experimental, not production-ready${NC}
                xenomai-libcobalt not yet integrated (no scarthgap meta-xenomai layer)
                Same userspace as preempt-rt; only kernel differs
                Requires Dovetail patches for BCM2712/arm64 — place in layers/ before building
  ${GREEN}qemu${NC}         QEMU x86-64 minimal image for CI testing

${BOLD}Examples:${NC}
  ./cclrte.sh build                    # PREEMPT_RT RPi5 (default)
  ./cclrte.sh build xenomai           # Xenomai Cobalt RPi5
  ./cclrte.sh load /dev/sdb                       # Flash PREEMPT_RT to SD (default)
  ./cclrte.sh load /dev/sdb xenomai              # Flash Xenomai to SD
  ./cclrte.sh load /dev/sda preempt-rt --force   # Override /dev/sda safety check

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
    load)   cmd_load "${2:-}" "${@:3}" ;;
    qemu)   cmd_qemu ;;
    help|-h|--help) cmd_help ;;
    *) error "Unknown command: $1"; cmd_help; exit 1 ;;
esac
