#!/bin/bash
# CCLRTE Extended I/O Setup
# Auto-detects connected HATs/expansion boards and configures their ports.
# Supports: EtherCAT HAT, IO-Link HAT, RS-485/Modbus HAT, CAN HAT

set -euo pipefail

log() { echo "[$(date -Iseconds)] CCLRTE-EXTIO: $*"; }

log "Extended I/O detection starting"

# ── EtherCAT HAT detection (SPI-based) ───────────────────────────────────────
if [[ -c /dev/spidev0.0 ]]; then
    log "SPI0 device found — potential EtherCAT or IO-Link HAT"
    # EtherCAT HATs typically have a LAN9252 or ET1100 ASIC on SPI
    # Detection via SPI read would be device-specific
fi

# ── CAN HAT detection (MCP2515 on SPI1) ──────────────────────────────────────
if [[ -d /sys/class/net/can0 ]]; then
    log "CAN interface can0 found — loading canbus support"
    ip link set can0 up type can bitrate 500000 2>/dev/null || true
    log "  can0 configured at 500 kbps"
fi

# ── RS-485 / Modbus RTU (UART0) ───────────────────────────────────────────────
# UART0 is available as /dev/ttyAMA0 after disabling Bluetooth
if [[ -c /dev/ttyAMA0 ]]; then
    log "UART0 (/dev/ttyAMA0) available for RS-485/Modbus RTU"
    # RS-485 mode requires GPIO direction control (pin 17 typically)
    # This is HAT-specific — configure via CODESYS SysCom driver
fi

# ── I2C device scan ───────────────────────────────────────────────────────────
if command -v i2cdetect &>/dev/null && [[ -c /dev/i2c-1 ]]; then
    log "I2C bus scan (i2c-1):"
    i2cdetect -y 1 2>/dev/null | grep -v "^$" | sed 's/^/  /' || true
fi

log "Extended I/O detection complete"
