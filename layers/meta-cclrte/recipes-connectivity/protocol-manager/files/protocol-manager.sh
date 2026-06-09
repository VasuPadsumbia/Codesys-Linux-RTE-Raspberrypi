#!/bin/bash
# CCLRTE Protocol Manager — mutual exclusivity for eth1 fieldbus protocols
# Author: Vasu Padsumbia
#
# Exactly one of EtherCAT / PROFINET / Modbus-TCP may be active on eth1 at a time.
# Usage: protocol-manager.sh <start|stop|status> <ethercat|profinet|modbus-tcp>

set -euo pipefail

STATE_FILE=/var/lib/cclrte/active-protocol
ETH1_IFACE=eth1
LOG=/var/log/cclrte-protocol.log

mkdir -p "$(dirname "$STATE_FILE")" "$(dirname "$LOG")"
log() { echo "[$(date '+%Y-%m-%dT%H:%M:%S')] PROTO-MGR: $*" | tee -a "$LOG"; }

VALID_PROTOCOLS=(ethercat profinet modbus-tcp)

usage() {
    echo "Usage: $0 <start|stop|status> <ethercat|profinet|modbus-tcp>"
    exit 1
}

[[ $# -lt 1 ]] && usage
ACTION="$1"
PROTOCOL="${2:-}"

# ── Status ────────────────────────────────────────────────────────────────────
cmd_status() {
    local active=""
    [[ -f "$STATE_FILE" ]] && active=$(cat "$STATE_FILE")
    echo "active_protocol=${active:-none}"
    for p in "${VALID_PROTOCOLS[@]}"; do
        local svc
        svc=$(proto_service "$p")
        local state
        state=$(systemctl is-active "$svc" 2>/dev/null || echo "inactive")
        echo "  ${p}: ${state}"
    done
}

proto_service() {
    case "$1" in
        ethercat)   echo "ethercat" ;;
        profinet)   echo "profinet" ;;
        modbus-tcp) echo "modbus-tcp" ;;
    esac
}

proto_stop() {
    local p="$1"
    local svc
    svc=$(proto_service "$p")
    log "Stopping ${p} (${svc}.service)"
    systemctl stop "$svc" 2>/dev/null || true
    systemctl disable "$svc" 2>/dev/null || true

    # Release eth1 back to networkd for IP assignment (Modbus TCP / PROFINET need IP)
    if [[ "$p" == "ethercat" ]]; then
        # EtherCAT uses raw socket — bring eth1 back as normal interface
        ip link set "$ETH1_IFACE" up 2>/dev/null || true
        systemctl restart systemd-networkd 2>/dev/null || true
    fi
}

proto_start() {
    local p="$1"
    local svc
    svc=$(proto_service "$p")

    case "$p" in
        ethercat)
            # EtherCAT uses raw socket — take eth1 out of networkd management
            systemctl stop systemd-networkd 2>/dev/null || true
            ip link set "$ETH1_IFACE" down 2>/dev/null || true
            ;;
        profinet | modbus-tcp)
            # These protocols need eth1 to have an IP
            ip link set "$ETH1_IFACE" up 2>/dev/null || true
            systemctl restart systemd-networkd 2>/dev/null || true
            sleep 1
            ;;
    esac

    log "Starting ${p} (${svc}.service)"
    systemctl enable "$svc" 2>/dev/null || true
    systemctl start  "$svc"
    echo "$p" > "$STATE_FILE"
    log "${p} active on ${ETH1_IFACE}"
}

# ── Start ─────────────────────────────────────────────────────────────────────
cmd_start() {
    [[ -z "$PROTOCOL" ]] && usage
    local valid=0
    for p in "${VALID_PROTOCOLS[@]}"; do [[ "$p" == "$PROTOCOL" ]] && valid=1; done
    [[ "$valid" -eq 0 ]] && { log "Unknown protocol: ${PROTOCOL}"; usage; }

    # Stop any currently active protocol first
    if [[ -f "$STATE_FILE" ]]; then
        local current
        current=$(cat "$STATE_FILE")
        if [[ -n "$current" && "$current" != "$PROTOCOL" ]]; then
            log "Stopping current protocol: ${current}"
            proto_stop "$current"
        fi
    fi

    proto_start "$PROTOCOL"
}

# ── Stop ──────────────────────────────────────────────────────────────────────
cmd_stop() {
    [[ -z "$PROTOCOL" ]] && {
        # Stop whatever is active
        if [[ -f "$STATE_FILE" ]]; then
            PROTOCOL=$(cat "$STATE_FILE")
        else
            log "No active protocol"
            exit 0
        fi
    }
    proto_stop "$PROTOCOL"
    echo "none" > "$STATE_FILE"
    log "${PROTOCOL} stopped"
}

case "$ACTION" in
    start)  cmd_start ;;
    stop)   cmd_stop  ;;
    status) cmd_status ;;
    *)      usage ;;
esac
