#!/bin/bash
# install-codesys-runtime.sh
# Installs CODESYS Control for Linux SL from a .deb package on a Yocto/OpenEmbedded system.
#
# Why this script exists:
#   Yocto images use opkg — they have NO dpkg, apt, or apt-get.
#   CODESYS distributes as a .deb, which is simply an ar(1) archive containing
#   a data.tar.* with the runtime filesystem content.
#   This script extracts data.tar.* directly into / without requiring dpkg.
#
# The CODESYS IDE's built-in "Update Raspberry Pi" deploy wizard runs `dpkg -i`
# over SSH — this will FAIL on Yocto. Use this script instead:
#
#   # From your PC:
#   scp CODESYSControl_linux_SL_*.deb root@192.168.2.100:/tmp/
#   ssh root@192.168.2.100
#   /usr/sbin/install-codesys-runtime.sh /tmp/CODESYSControl_linux_SL_*.deb
#
# After successful installation the codesys-post-install.sh script is called
# automatically to apply RT tuning and start the runtime service.

set -euo pipefail

log() { echo "[$(date '+%Y-%m-%dT%H:%M:%S')] CODESYS-INSTALL: $*"; }
die() { log "ERROR: $*" >&2; exit 1; }

[[ $EUID -eq 0 ]] || die "Must be run as root (use: sudo $0 $*)"
[[ $# -ge 1 ]] || die "Usage: $0 <CODESYSControl_linux_SL_*.deb>"

DEB="$1"
[[ -f "$DEB" ]] || die "File not found: $DEB"

# Verify this looks like a .deb (ar archive magic bytes)
file_magic=$(head -c 8 "$DEB" 2>/dev/null || true)
case "$file_magic" in
    "!<arch>"*) : ;;  # correct
    *) die "Not a valid .deb file — expected ar(1) archive. Got: $(file "$DEB" 2>/dev/null || echo 'unknown')" ;;
esac

log "Installing from: $DEB"
log "Package size:    $(du -sh "$DEB" | cut -f1)"

# ── Check ar is available ──────────────────────────────────────────────────────
if ! command -v ar &>/dev/null; then
    die "'ar' not found. Ensure binutils is installed (opkg install binutils) and retry."
fi

# ── Temporary extraction directory ────────────────────────────────────────────
TMPDIR=$(mktemp -d /tmp/codesys-install-XXXXXX)
trap 'rm -rf "$TMPDIR"' EXIT

cd "$TMPDIR"
log "Extracting .deb archive..."
ar x "$DEB"

# ── Locate data.tar.* — may be .gz .xz .bz2 or .zst ──────────────────────────
DATA_TAR=$(ls data.tar.* 2>/dev/null | head -1 || true)
[[ -n "$DATA_TAR" ]] || die "data.tar.* not found inside .deb — unexpected package format. Contents: $(ls -la)"

log "Found payload: $DATA_TAR"

# ── Install filesystem content ─────────────────────────────────────────────────
log "Extracting runtime to / ..."
tar xf "$DATA_TAR" -C /

# ── Shared library cache ───────────────────────────────────────────────────────
ldconfig 2>/dev/null || true

# ── Verify the key binary is present ──────────────────────────────────────────
if [[ ! -x /opt/codesys/bin/codesyscontrol ]]; then
    die "Installation failed: /opt/codesys/bin/codesyscontrol not found after extraction."
fi

log "CODESYS runtime installed:"
log "  Runtime: /opt/codesys/bin/codesyscontrol"
ls /opt/codesys/bin/ 2>/dev/null && true
ls /opt/codesys/gateway/ 2>/dev/null && true

# ── Run post-install RT configuration ─────────────────────────────────────────
if [[ -x /usr/sbin/codesys-post-install.sh ]]; then
    log "Applying RT configuration and starting services..."
    /usr/sbin/codesys-post-install.sh
else
    log "WARNING: /usr/sbin/codesys-post-install.sh not found."
    log "Start CODESYS manually: systemctl enable --now codesyscontrol"
fi
