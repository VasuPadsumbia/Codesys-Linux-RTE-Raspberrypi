#!/bin/bash
# install-codesys-runtime.sh
# Installs CODESYS Control for Linux SL from a .deb package on a Yocto/OpenEmbedded system.
#
# Why this script exists:
#   Yocto images use opkg — they have NO dpkg, apt, or apt-get.
#   CODESYS distributes as a .deb, which is simply an ar(1) archive containing
#   a data.tar.* with the runtime filesystem content.
#   This script extracts data.tar.* directly into / using Python3 (always
#   available) without requiring dpkg, ar, or binutils.
#
# The CODESYS IDE's "Update Raspberry Pi" deploy wizard runs `dpkg -i` over SSH
# and reads /proc/cpuinfo for a "Model" or "Hardware" field — both will FAIL on
# Yocto. Use this script instead:
#
#   # From your PC:
#   scp CODESYSControl_linux_SL_*.deb root@192.168.2.100:/tmp/
#   ssh root@192.168.2.100
#   /usr/sbin/install-codesys-runtime.sh /tmp/CODESYSControl_linux_SL_*.deb
#
# After installation codesys-post-install.sh applies RT tuning and starts services.

set -euo pipefail

log() { echo "[$(date '+%Y-%m-%dT%H:%M:%S')] CODESYS-INSTALL: $*"; }
die() { log "ERROR: $*" >&2; exit 1; }

[[ $EUID -eq 0 ]] || die "Must be run as root"
[[ $# -ge 1 ]] || die "Usage: $0 <CODESYSControl_linux_SL_*.deb>"

DEB="$1"
[[ -f "$DEB" ]] || die "File not found: $DEB"

# Verify ar magic bytes (!<arch>)
# BusyBox head has no -c (byte-count) flag — use dd instead.
MAGIC=$(dd if="$DEB" bs=8 count=1 2>/dev/null)
[[ "$MAGIC" == '!<arch>' ]] || die "Not a valid .deb file — expected ar archive magic '!<arch>'"

log "Installing from: $DEB"
log "Package size:    $(du -sh "$DEB" | cut -f1)"

# ── Temporary extraction directory ────────────────────────────────────────────
TMPDIR=$(mktemp -d /tmp/codesys-install-XXXXXX)
trap 'rm -rf "$TMPDIR"' EXIT

# ── Extract .deb via Python3 (no ar/binutils dependency) ──────────────────────
# A .deb is an ar(1) archive: 8-byte magic + repeated 60-byte headers + data.
# We parse it in Python to find and extract data.tar.* without external tools.
log "Extracting .deb archive (Python3)..."

DATA_TAR=$(python3 - "$DEB" "$TMPDIR" << 'PYEOF'
import sys, os, struct

deb_path  = sys.argv[1]
dest_dir  = sys.argv[2]

with open(deb_path, 'rb') as f:
    magic = f.read(8)
    if magic != b'!<arch>\n':
        sys.exit(f"Not an ar archive: {magic!r}")

    while True:
        header = f.read(60)
        if len(header) < 60:
            break
        # ar header: name(16) mtime(12) uid(6) gid(6) mode(8) size(10) magic(2)
        name = header[0:16].decode('ascii', errors='replace').strip().rstrip('/')
        try:
            size = int(header[48:58].decode().strip())
        except ValueError:
            break
        data = f.read(size)
        if size % 2:          # ar pads members to even offsets
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

[[ -f "$DATA_TAR" ]] || die "Python extraction failed — data.tar not produced"
log "Found payload: $(basename "$DATA_TAR")"

# ── Install filesystem content ─────────────────────────────────────────────────
log "Extracting runtime to / ..."
tar xf "$DATA_TAR" -C /

# ── Shared library cache ───────────────────────────────────────────────────────
ldconfig 2>/dev/null || true

# ── Locate installed binary (path varies by CODESYS version/package) ──────────
# v3.x SL package  : /opt/codesys/bin/codesyscontrol
# v4.x linuxarm64  : /opt/codesyscontrol/bin/codesyscontrol  OR  /usr/sbin/codesyscontrol
CODESYS_BIN=$(find /opt /usr/sbin /usr/bin \
    \( -name "codesyscontrol.bin" -o -name "codesyscontrol" \) \
    -type f -perm /0111 2>/dev/null | head -1)

if [[ -z "$CODESYS_BIN" ]]; then
    log "Could not find codesyscontrol binary. Files extracted to /:"
    # Show what was actually installed so the user can report the path
    find /opt /usr/share/codesys* /usr/lib/codesys* \
        -maxdepth 5 2>/dev/null | head -40 | sed 's/^/  /'
    die "Installation failed: codesyscontrol binary not found — check paths above"
fi

log "CODESYS runtime installed successfully"
log "  Binary: $CODESYS_BIN"
ls "$(dirname "$CODESYS_BIN")/" 2>/dev/null | sed 's/^/  /'

# Update codesyscontrol.service ExecStart if it points to old path
SVC=/etc/systemd/system/codesyscontrol.service
if [[ -f "$SVC" ]] && ! grep -q "ExecStart=${CODESYS_BIN}" "$SVC"; then
    sed -i "s|ExecStart=.*codesyscontrol|ExecStart=${CODESYS_BIN}|" "$SVC" 2>/dev/null || true
    log "  Service ExecStart updated to: $CODESYS_BIN"
fi

# ── Run post-install RT configuration ─────────────────────────────────────────
if [[ -x /usr/sbin/codesys-post-install.sh ]]; then
    log "Applying RT configuration and starting services..."
    /usr/sbin/codesys-post-install.sh
else
    log "WARNING: codesys-post-install.sh not found — start manually:"
    log "  systemctl enable --now codesyscontrol"
fi
