#!/bin/bash
# install-codesys-runtime.sh
# Author: Vasu Padsumbia
#
# Installs CODESYS Control for Linux SL on a Yocto/OpenEmbedded system.
#
# Accepts both .deb and .ipk packages. Both should be provided:
#   - .deb  : main runtime binary (codesyscontrol)
#   - .ipk  : component libraries (libCmpRetain.so etc.) + post-install
#
# Why this script exists:
#   Yocto images use opkg — they have NO dpkg, apt, or apt-get.
#   .deb packages are extracted via Python3 (always available).
#   .ipk packages are installed via opkg (Yocto's native package manager).
#
# USAGE:
#   /usr/sbin/install-codesys-runtime.sh <package.deb> [<package.ipk>]
#   /usr/sbin/install-codesys-runtime.sh /opt/codesys-packages/*.deb /opt/codesys-packages/*.ipk
#
# Bundled packages (if flashed from Yocto image):
#   /opt/codesys-packages/codesyscontrol_linuxarm64_*.deb
#   /opt/codesys-packages/codesyscontrol_linuxarm64_*.ipk

set -euo pipefail

log() { echo "[$(date '+%Y-%m-%dT%H:%M:%S')] CODESYS-INSTALL: $*"; }
die() { log "ERROR: $*" >&2; exit 1; }

[[ $EUID -eq 0 ]] || die "Must be run as root"
[[ $# -ge 1 ]]    || die "Usage: $0 <package.deb> [<package.ipk>]
  Both .deb and .ipk should be provided for a complete installation.
  Bundled packages: /opt/codesys-packages/*.deb /opt/codesys-packages/*.ipk"

# ── Sort files by type ────────────────────────────────────────────────────────
DEB_FILES=()
IPK_FILES=()
for PKG in "$@"; do
    [[ -f "$PKG" ]] || die "File not found: $PKG"
    case "$PKG" in
        *.deb) DEB_FILES+=("$PKG") ;;
        *.ipk) IPK_FILES+=("$PKG") ;;
        *) die "Unsupported package format: $PKG (only .deb and .ipk are supported)" ;;
    esac
done

# ── Install .deb packages (via Python ar extraction — no dpkg needed) ─────────
install_deb() {
    local DEB="$1"
    # Verify ar magic bytes (!<arch>) using dd (BusyBox compatible)
    local MAGIC
    MAGIC=$(dd if="$DEB" bs=8 count=1 2>/dev/null)
    [[ "$MAGIC" == '!<arch>' ]] || die "Not a valid .deb file: $DEB"

    log "Installing .deb: $(basename "$DEB") ($(du -sh "$DEB" | cut -f1))"

    local TMPDIR
    TMPDIR=$(mktemp -d /tmp/codesys-install-XXXXXX)
    # shellcheck disable=SC2064
    trap "rm -rf '$TMPDIR'" EXIT

    # Extract data.tar.* from the .deb ar archive using Python3
    local DATA_TAR
    DATA_TAR=$(python3 - "$DEB" "$TMPDIR" << 'PYEOF'
import sys, os, struct

deb_path = sys.argv[1]
dest_dir = sys.argv[2]

with open(deb_path, 'rb') as f:
    magic = f.read(8)
    if magic != b'!<arch>\n':
        sys.exit(f"Not an ar archive: {magic!r}")
    while True:
        header = f.read(60)
        if len(header) < 60:
            break
        name = header[0:16].decode('ascii', errors='replace').strip().rstrip('/')
        try:
            size = int(header[48:58].decode().strip())
        except ValueError:
            break
        data = f.read(size)
        if size % 2:
            f.read(1)
        if name.startswith('data.tar'):
            out_path = os.path.join(dest_dir, name)
            with open(out_path, 'wb') as out:
                out.write(data)
            print(out_path)
            sys.exit(0)

sys.exit("data.tar.* member not found inside .deb")
PYEOF
    )

    [[ -f "$DATA_TAR" ]] || die "Python extraction failed for: $DEB"
    log "Extracting to / ..."
    tar xf "$DATA_TAR" -C /
    log ".deb installed: $(basename "$DEB")"
    trap - EXIT
    rm -rf "$TMPDIR"
}

# ── Install .ipk packages (via opkg — Yocto's native package manager) ────────
install_ipk() {
    local IPK="$1"
    log "Installing .ipk: $(basename "$IPK") ($(du -sh "$IPK" | cut -f1))"

    if command -v opkg &>/dev/null; then
        # Primary: use opkg — handles dependencies and post-install scripts
        opkg install --nodeps --force-reinstall "$IPK" 2>&1 | \
            sed 's/^/  [opkg] /' || {
            log "opkg install failed, falling back to manual extraction"
            install_ipk_manual "$IPK"
        }
    else
        log "opkg not found, using manual extraction"
        install_ipk_manual "$IPK"
    fi
    log ".ipk installed: $(basename "$IPK")"
}

# Fallback: extract .ipk manually (same ar format as .deb)
install_ipk_manual() {
    local IPK="$1"
    local TMPDIR
    TMPDIR=$(mktemp -d /tmp/codesys-ipk-XXXXXX)
    trap "rm -rf '$TMPDIR'" EXIT

    python3 - "$IPK" "$TMPDIR" << 'PYEOF'
import sys, os
ipk_path = sys.argv[1]
dest_dir = sys.argv[2]
with open(ipk_path, 'rb') as f:
    if f.read(8) != b'!<arch>\n':
        sys.exit("Not an ar archive")
    while True:
        header = f.read(60)
        if len(header) < 60: break
        name = header[0:16].decode('ascii', errors='replace').strip().rstrip('/')
        size = int(header[48:58].decode().strip())
        data = f.read(size)
        if size % 2: f.read(1)
        if name.startswith('data.tar'):
            out = os.path.join(dest_dir, name)
            open(out, 'wb').write(data)
            print(out)
            sys.exit(0)
sys.exit("data.tar not found")
PYEOF
    local DATA_TAR
    DATA_TAR=$(ls "$TMPDIR"/data.tar.* 2>/dev/null | head -1)
    [[ -f "$DATA_TAR" ]] || die "IPK extraction failed: no data.tar found"
    tar xf "$DATA_TAR" -C /
    trap - EXIT
    rm -rf "$TMPDIR"
}

# ── Install in order: .deb first (binary), then .ipk (component libs) ────────
for DEB in "${DEB_FILES[@]}"; do
    install_deb "$DEB"
done

for IPK in "${IPK_FILES[@]}"; do
    install_ipk "$IPK"
done

# ── Update shared library cache ────────────────────────────────────────────────
ldconfig 2>/dev/null || true

# ── Locate installed binary ───────────────────────────────────────────────────
CODESYS_BIN=$(find /opt /usr/sbin /usr/bin \
    \( -name "codesyscontrol.bin" -o -name "codesyscontrol" \) \
    -type f -perm /0111 2>/dev/null | head -n 1)

if [[ -z "$CODESYS_BIN" ]]; then
    log "Could not find codesyscontrol binary. Files extracted to /:"
    find /opt /usr/share/codesys* /usr/lib/codesys* \
        -maxdepth 5 2>/dev/null | head -n 40 | sed 's/^/  /'
    die "Installation failed: codesyscontrol binary not found"
fi

BIN_DIR="$(dirname "$CODESYS_BIN")"
log "Binary: $CODESYS_BIN"

# Create canonical symlink (some .deb versions install as codesyscontrol.bin)
if [[ "$(basename "$CODESYS_BIN")" == "codesyscontrol.bin" ]]; then
    if [[ ! -e "${BIN_DIR}/codesyscontrol" ]]; then
        ln -sf "$CODESYS_BIN" "${BIN_DIR}/codesyscontrol"
        log "Symlink: ${BIN_DIR}/codesyscontrol → $CODESYS_BIN"
    fi
fi

# ── Apply RT configuration and start services ─────────────────────────────────
if [[ -x /usr/sbin/codesys-post-install.sh ]]; then
    log "Applying RT configuration (CPU3, SCHED_FIFO 80) and starting services..."
    /usr/sbin/codesys-post-install.sh
else
    log "WARNING: codesys-post-install.sh not found"
    systemctl enable --now codesyscontrol.service 2>/dev/null || true
fi

# ── Summary ────────────────────────────────────────────────────────────────────
echo ""
log "══════════════════════════════════════════════════════════"
log "  CODESYS installation complete"
log "  Binary: $CODESYS_BIN"
log "══════════════════════════════════════════════════════════"
echo ""
log "  Connect CODESYS IDE:"
ETH0_IP=$(ip -4 addr show eth0 2>/dev/null | awk '/inet /{print $2}' | cut -d/ -f1 | head -1)
log "    Tools → Communication → Add Gateway"
log "    IP: ${ETH0_IP:-192.168.2.100}    Port: 1217"
echo ""
log "  Verify runtime:"
log "    systemctl status codesyscontrol"
log "    ss -tlnp | grep 1217"
echo ""
