#!/bin/bash
# CCLRTE — Development Environment Setup
# Author: Vasu Padsumbia
#
# Run once on a fresh Ubuntu 22.04/24.04 host before your first build.
# Safe to re-run: all steps are idempotent.
#
# Usage:
#   ./setup.sh           # Full setup (installs system packages — needs sudo)
#   ./setup.sh --no-apt  # Skip apt install (already installed or non-root)
#   ./setup.sh --check   # Only check requirements, install nothing

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
VENV_DIR="${SCRIPT_DIR}/venv"

# ── Colors ────────────────────────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
BLUE='\033[0;34m'; CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'

info()    { echo -e "${BLUE}[INFO]${NC}  $*"; }
ok()      { echo -e "${GREEN}[ OK ]${NC}  $*"; }
warn()    { echo -e "${YELLOW}[WARN]${NC}  $*"; }
error()   { echo -e "${RED}[FAIL]${NC}  $*" >&2; }
step()    { echo -e "\n${BOLD}── $* ─────────────────────────────────────────${NC}"; }
die()     { error "$*"; exit 1; }

CHECK_ONLY=false
SKIP_APT=false
for arg in "$@"; do
    case "$arg" in
        --check)   CHECK_ONLY=true ;;
        --no-apt)  SKIP_APT=true ;;
        -h|--help)
            echo "Usage: $0 [--check] [--no-apt]"
            echo "  --check    Only verify requirements, install nothing"
            echo "  --no-apt   Skip apt package installation"
            exit 0 ;;
        *) die "Unknown option: $arg" ;;
    esac
done

ERRORS=0
WARNINGS=0
track_error()   { (( ERRORS++ ))   || true; }
track_warning() { (( WARNINGS++ )) || true; }

# ─────────────────────────────────────────────────────────────────────────────
step "System Checks"
# ─────────────────────────────────────────────────────────────────────────────

# ── OS version ────────────────────────────────────────────────────────────────
if [[ -f /etc/os-release ]]; then
    # shellcheck source=/dev/null
    source /etc/os-release
    case "${VERSION_ID:-}" in
        22.04|24.04) ok "OS: ${PRETTY_NAME}" ;;
        *)
            warn "Untested OS: ${PRETTY_NAME} — build validated on Ubuntu 22.04/24.04 LTS"
            track_warning ;;
    esac
else
    warn "Cannot detect OS — /etc/os-release not found"
    track_warning
fi

# ── CPU cores ─────────────────────────────────────────────────────────────────
CPUS=$(nproc)
if [[ "$CPUS" -lt 4 ]]; then
    warn "CPU cores: ${CPUS} — Yocto builds are slow with fewer than 4 cores"
    track_warning
else
    ok "CPU cores: ${CPUS}"
fi

# ── RAM ───────────────────────────────────────────────────────────────────────
RAM_KB=$(grep MemTotal /proc/meminfo | awk '{print $2}')
RAM_GB=$(( RAM_KB / 1024 / 1024 ))
if [[ "$RAM_GB" -lt 6 ]]; then
    error "RAM: ${RAM_GB} GB — minimum 6 GB required for Yocto builds"
    track_error
elif [[ "$RAM_GB" -lt 8 ]]; then
    warn  "RAM: ${RAM_GB} GB — 8 GB recommended; limit parallelism: BB_NUMBER_THREADS = \"4\" PARALLEL_MAKE = \"-j4\""
    warn  "  WSL2: add 'memory=12GB' to %USERPROFILE%\\.wslconfig and restart WSL"
    track_warning
elif [[ "$RAM_GB" -lt 16 ]]; then
    warn  "RAM: ${RAM_GB} GB — 16 GB recommended (builds may be slow)"
    track_warning
else
    ok "RAM: ${RAM_GB} GB"
fi

# ── Disk space ────────────────────────────────────────────────────────────────
AVAIL_KB=$(df -k "$SCRIPT_DIR" | tail -1 | awk '{print $4}')
AVAIL_GB=$(( AVAIL_KB / 1024 / 1024 ))
if [[ "$AVAIL_GB" -lt 80 ]]; then
    error "Disk: ${AVAIL_GB} GB free — need at least 80 GB (150 GB recommended)"
    track_error
elif [[ "$AVAIL_GB" -lt 150 ]]; then
    warn  "Disk: ${AVAIL_GB} GB free — 150 GB recommended for full build + sstate"
    track_warning
else
    ok "Disk: ${AVAIL_GB} GB free"
fi

# ── git config ────────────────────────────────────────────────────────────────
GIT_NAME=$(git config --global user.name  2>/dev/null || true)
GIT_EMAIL=$(git config --global user.email 2>/dev/null || true)
if [[ -z "$GIT_NAME" || -z "$GIT_EMAIL" ]]; then
    warn "git identity not set — set it to avoid Yocto fetch errors:"
    warn "  git config --global user.name  'Your Name'"
    warn "  git config --global user.email 'you@example.com'"
    track_warning
else
    ok "git identity: ${GIT_NAME} <${GIT_EMAIL}>"
fi

# ─────────────────────────────────────────────────────────────────────────────
step "System Packages"
# ─────────────────────────────────────────────────────────────────────────────

APT_PACKAGES=(
    # Yocto core build tools
    git wget curl file
    gcc g++ make diffstat texinfo chrpath socat
    cpio lz4 zstd xterm
    # Python
    python3 python3-pip python3-venv
    # Yocto extra
    gawk unzip locales
    libsdl1.2-dev
    # SSL/kernel build
    libssl-dev libelf-dev
    # SD card flash progress
    pv
)

if $CHECK_ONLY || $SKIP_APT; then
    missing=()
    for pkg in "${APT_PACKAGES[@]}"; do
        dpkg -s "$pkg" &>/dev/null || missing+=("$pkg")
    done
    if [[ ${#missing[@]} -eq 0 ]]; then
        ok "All required packages installed"
    else
        error "Missing packages: ${missing[*]}"
        $CHECK_ONLY || info "Run without --no-apt to install them, or: sudo apt install ${missing[*]}"
        track_error
    fi
else
    if [[ $EUID -ne 0 ]] && ! sudo -n true 2>/dev/null; then
        warn "sudo required to install packages — you may be prompted for a password"
    fi
    info "Installing system packages..."
    sudo apt-get update -qq
    sudo apt-get install -y --no-install-recommends "${APT_PACKAGES[@]}"
    ok "System packages installed"
fi

# ─────────────────────────────────────────────────────────────────────────────
step "Locale"
# ─────────────────────────────────────────────────────────────────────────────

if locale -a 2>/dev/null | grep -q "en_US.utf8"; then
    ok "Locale en_US.UTF-8 available"
else
    if $CHECK_ONLY || $SKIP_APT; then
        error "en_US.UTF-8 locale not generated — run: sudo locale-gen en_US.UTF-8"
        track_error
    else
        info "Generating en_US.UTF-8 locale..."
        sudo locale-gen en_US.UTF-8
        ok "Locale generated"
    fi
fi

# ─────────────────────────────────────────────────────────────────────────────
step "Python Virtual Environment"
# ─────────────────────────────────────────────────────────────────────────────

if $CHECK_ONLY; then
    if [[ -x "${VENV_DIR}/bin/kas" ]]; then
        KAS_VER=$("${VENV_DIR}/bin/kas" --version 2>/dev/null | head -1 || echo "unknown")
        ok "venv present — kas: ${KAS_VER}"
    else
        error "venv not found at venv/ — run setup.sh without --check"
        track_error
    fi
else
    if [[ ! -d "$VENV_DIR" ]]; then
        info "Creating Python virtual environment..."
        python3 -m venv "$VENV_DIR"
    else
        info "venv already exists — updating..."
    fi
    # shellcheck source=/dev/null
    source "${VENV_DIR}/bin/activate"
    pip install --quiet --upgrade pip
    pip install --quiet -r "${SCRIPT_DIR}/requirements.txt"
    KAS_VER=$("${VENV_DIR}/bin/kas" --version 2>/dev/null | head -1 || echo "unknown")
    ok "venv ready — kas: ${KAS_VER}"
fi

# ── KAS version check ─────────────────────────────────────────────────────────
KAS_BIN="${VENV_DIR}/bin/kas"
if [[ -x "$KAS_BIN" ]]; then
    KAS_MAJOR=$("$KAS_BIN" --version 2>/dev/null | grep -oP '\d+\.\d+' | head -1 | cut -d. -f1 || echo 0)
    if [[ "$KAS_MAJOR" -lt 4 ]]; then
        error "kas version too old — need >= 4.0 (KAS config format version 14)"
        track_error
    fi
fi

# ─────────────────────────────────────────────────────────────────────────────
step "Site Configuration"
# ─────────────────────────────────────────────────────────────────────────────

SITE_CONF="${SCRIPT_DIR}/config/site.conf"
SITE_SAMPLE="${SCRIPT_DIR}/config/site.conf.sample"

if [[ -f "$SITE_CONF" ]]; then
    ok "config/site.conf exists"
    # Check for unfilled placeholder values
    if grep -q '^WIFI_SSID=""' "$SITE_CONF" 2>/dev/null; then
        warn "config/site.conf: WIFI_SSID is empty — WiFi will not connect on first boot"
        track_warning
    fi
    if grep -q '^SSH_AUTHORIZED_KEY=""' "$SITE_CONF" 2>/dev/null; then
        warn "config/site.conf: SSH_AUTHORIZED_KEY is empty — add your public key for SSH access"
        info "  Generate one: ssh-keygen -t ed25519 -C 'cclrte'"
        info "  Then paste the contents of ~/.ssh/id_ed25519.pub into config/site.conf"
        track_warning
    fi
else
    if $CHECK_ONLY; then
        warn "config/site.conf not found — network will use image defaults (eth0 192.168.2.100)"
        track_warning
    else
        info "Creating config/site.conf from sample..."
        cp "$SITE_SAMPLE" "$SITE_CONF"
        warn "config/site.conf created — edit it before building:"
        warn "  ${SITE_CONF}"
        echo ""
        echo -e "  ${CYAN}nano config/site.conf${NC}   # set WIFI_SSID, WIFI_PASSWORD, SSH_AUTHORIZED_KEY"
        track_warning
    fi
fi

# ─────────────────────────────────────────────────────────────────────────────
step "SSH Key"
# ─────────────────────────────────────────────────────────────────────────────

if ls ~/.ssh/id_*.pub &>/dev/null 2>&1; then
    KEY=$(ls ~/.ssh/id_*.pub | head -1)
    ok "SSH public key found: ${KEY}"
    info "  Paste its contents into config/site.conf SSH_AUTHORIZED_KEY field"
else
    warn "No SSH public key found in ~/.ssh/ — create one for passwordless device access:"
    info "  ssh-keygen -t ed25519 -C 'cclrte-dev'"
    info "  Then add ~/.ssh/id_ed25519.pub to config/site.conf"
    track_warning
fi

# ─────────────────────────────────────────────────────────────────────────────
step "Build Targets"
# ─────────────────────────────────────────────────────────────────────────────

for kas_file in kas/rpi5-64.yml kas/rpi5-xenomai.yml kas/qemu-x86-64.yml; do
    if [[ -f "${SCRIPT_DIR}/${kas_file}" ]]; then
        ok "KAS config: ${kas_file}"
    else
        error "KAS config missing: ${kas_file}"
        track_error
    fi
done

# ─────────────────────────────────────────────────────────────────────────────
step "Summary"
# ─────────────────────────────────────────────────────────────────────────────

echo ""
if [[ "$ERRORS" -gt 0 ]]; then
    error "${ERRORS} error(s) found — resolve them before building"
    [[ "$WARNINGS" -gt 0 ]] && warn "${WARNINGS} warning(s) — review above"
    echo ""
    exit 1
elif [[ "$WARNINGS" -gt 0 ]]; then
    warn "${WARNINGS} warning(s) — review above, then proceed"
    echo ""
else
    ok "All checks passed"
    echo ""
fi

if ! $CHECK_ONLY; then
    echo -e "${BOLD}Next steps:${NC}"
    echo ""
    echo -e "  ${CYAN}1. Edit site config:${NC}"
    echo -e "     nano config/site.conf"
    echo -e "     # Set WIFI_SSID, WIFI_PASSWORD, WIFI_COUNTRY, SSH_AUTHORIZED_KEY"
    echo ""
    echo -e "  ${CYAN}2. Build (PREEMPT_RT, recommended first):${NC}"
    echo -e "     ./cclrte.sh build preempt-rt"
    echo ""
    echo -e "  ${CYAN}3. Flash SD card:${NC}"
    echo -e "     ./cclrte.sh load /dev/sdX preempt-rt"
    echo ""
    echo -e "  ${CYAN}4. Connect to device (after first boot):${NC}"
    echo -e "     ssh root@192.168.2.100   # Ethernet"
    echo -e "     # Default password: cclrte"
    echo ""
    echo -e "  ${CYAN}5. Clean recipe sstate after editing meta-cclrte:${NC}"
    echo -e "     ./cclrte.sh clean recipes preempt-rt"
    echo ""
    echo -e "  See ${CYAN}docs/INSTALLATION.md${NC} for detailed steps."
    echo ""
fi
