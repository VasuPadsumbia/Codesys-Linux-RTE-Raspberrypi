#!/usr/bin/env bash
# test_protocols.sh — Integration tests for the full protocol stack on target RPi4.
#
# Run ON the target (via SSH or directly):
#   ssh root@192.168.1.100 bash < tests/integration/test_protocols.sh
#
# Tests: MQTT, OPC-UA, IO-Link, PROFINET, Modbus UART, CAN, network isolation, gateway port
#
# Exit codes:
#   0 — all mandatory checks passed
#   1 — one or more mandatory checks failed

set -euo pipefail

PASS=0
FAIL=0
SKIP=0

check() {
    local desc="$1"
    local result="$2"
    if [[ "$result" == "pass" ]]; then
        echo "  PASS: $desc"
        ((PASS++)) || true
    elif [[ "$result" == "skip" ]]; then
        echo "  SKIP: $desc"
        ((SKIP++)) || true
    else
        echo "  FAIL: $desc — $result"
        ((FAIL++)) || true
    fi
}

echo "=== Protocol Stack Integration Test ==="
echo "Target: $(hostname) — $(date -Iseconds)"
echo ""

# ---------------------------------------------------------------------------
# [1] MQTT — Mosquitto broker
# ---------------------------------------------------------------------------
echo "[1] MQTT (Mosquitto)"

if systemctl is-active mosquitto &>/dev/null; then
    check "mosquitto.service is active" "pass"
else
    check "mosquitto.service is active" "service inactive"
fi

if ss -tlnp 2>/dev/null | grep -q ":1883 "; then
    check "MQTT port 1883 is listening" "pass"
else
    check "MQTT port 1883 is listening" "port not listening"
fi

if ss -tlnp 2>/dev/null | grep -q ":9001 "; then
    check "MQTT WebSocket port 9001 is listening" "pass"
else
    check "MQTT WebSocket port 9001 is listening" "port not listening"
fi

# Publish-subscribe round-trip test
if command -v mosquitto_pub &>/dev/null && command -v mosquitto_sub &>/dev/null; then
    TEST_TOPIC="cclrte/test/$(date +%s)"
    TEST_MSG="ping-$(hostname)"
    # Subscribe in background, publish, capture received
    mosquitto_sub -h localhost -t "$TEST_TOPIC" -C 1 -W 3 > /tmp/mqtt_recv.txt 2>/dev/null &
    SUB_PID=$!
    sleep 0.2
    mosquitto_pub -h localhost -t "$TEST_TOPIC" -m "$TEST_MSG" 2>/dev/null
    wait "$SUB_PID" 2>/dev/null || true
    if grep -q "$TEST_MSG" /tmp/mqtt_recv.txt 2>/dev/null; then
        check "MQTT publish-subscribe round-trip" "pass"
    else
        check "MQTT publish-subscribe round-trip" "message not received"
    fi
    rm -f /tmp/mqtt_recv.txt
else
    check "MQTT round-trip test (mosquitto tools)" "skip"
    echo "  INFO: Install mosquitto-clients to enable round-trip test"
fi

# ---------------------------------------------------------------------------
# [2] OPC-UA
# ---------------------------------------------------------------------------
echo ""
echo "[2] OPC-UA (open62541 / CODESYS OPC UA Server SL)"

if ss -tlnp 2>/dev/null | grep -q ":4840 "; then
    check "OPC-UA port 4840 is listening" "pass"
else
    check "OPC-UA port 4840 listening" "skip"
    echo "  INFO: OPC-UA port 4840 only active when CODESYS OPC UA Server SL is licensed and running"
fi

if command -v nc &>/dev/null; then
    if nc -z -w2 127.0.0.1 4840 2>/dev/null; then
        check "OPC-UA TCP connection (nc)" "pass"
    else
        check "OPC-UA TCP connection (nc)" "skip"
    fi
else
    check "OPC-UA TCP connectivity (nc not available)" "skip"
fi

# ---------------------------------------------------------------------------
# [3] IO-Link (SPI0)
# ---------------------------------------------------------------------------
echo ""
echo "[3] IO-Link (SPI0)"

if [[ -c /dev/spidev0.0 ]]; then
    check "/dev/spidev0.0 exists (SPI0 for IO-Link)" "pass"
else
    check "/dev/spidev0.0 exists" "device not found — check dtparam=spi=on in config.txt"
fi

if [[ -c /dev/spidev0.1 ]]; then
    check "/dev/spidev0.1 exists (SPI0 CS1)" "pass"
else
    check "/dev/spidev0.1 exists" "skip"
fi

if systemctl is-active iolink-master &>/dev/null 2>&1; then
    check "iolink-master.service is active" "pass"
elif systemctl list-unit-files iolink-master.service &>/dev/null 2>&1; then
    check "iolink-master.service exists" "pass"
else
    check "iolink-master service check" "skip"
    echo "  INFO: iolink-master service may need IO-Link HAT hardware"
fi

# ---------------------------------------------------------------------------
# [4] PROFINET (p-net device stack)
# ---------------------------------------------------------------------------
echo ""
echo "[4] PROFINET (p-net — device/slave mode)"

if systemctl is-active profinet &>/dev/null 2>&1 || systemctl is-active p-net &>/dev/null 2>&1; then
    check "PROFINET service is active" "pass"
else
    check "PROFINET service" "skip"
    echo "  INFO: p-net PROFINET device stack — requires a PROFINET controller (master) to connect"
fi

# PROFINET uses UDP ports 34962, 34963, 34964
for port in 34962 34963 34964; do
    if ss -ulnp 2>/dev/null | grep -q ":${port} "; then
        check "PROFINET UDP port ${port}" "pass"
    else
        check "PROFINET UDP port ${port}" "skip"
    fi
done

# ---------------------------------------------------------------------------
# [5] Modbus / RS-485 UART
# ---------------------------------------------------------------------------
echo ""
echo "[5] Modbus RS-485 (UART0)"

if [[ -c /dev/ttyAMA0 ]]; then
    check "/dev/ttyAMA0 exists (PL011 UART0 — RS-485 Modbus)" "pass"
else
    check "/dev/ttyAMA0 exists" "device not found — check dtoverlay=disable-bt in config.txt"
fi

# Verify UART0 is not consumed by Bluetooth
if [[ -d /proc/device-tree/aliases ]]; then
    BT_UART=$(cat /proc/device-tree/aliases/bluetooth 2>/dev/null || echo "")
    if [[ -z "$BT_UART" ]] || ! echo "$BT_UART" | grep -q "uart0"; then
        check "UART0 not consumed by Bluetooth" "pass"
    else
        check "UART0 not consumed by Bluetooth" "Bluetooth is using UART0 — check dtoverlay=disable-bt"
    fi
else
    check "UART0 Bluetooth check" "skip"
fi

# ---------------------------------------------------------------------------
# [6] CAN (MCP2515 / SocketCAN)
# ---------------------------------------------------------------------------
echo ""
echo "[6] CAN (SocketCAN)"

if ip link 2>/dev/null | grep -q "can"; then
    CAN_IFACE=$(ip link 2>/dev/null | grep "can" | awk -F': ' '{print $2}' | head -1)
    check "CAN interface found ($CAN_IFACE)" "pass"
    if ip link show "$CAN_IFACE" 2>/dev/null | grep -q "UP"; then
        check "CAN interface is UP" "pass"
    else
        check "CAN interface UP" "skip"
        echo "  INFO: Bring up with: ip link set $CAN_IFACE up type can bitrate 500000"
    fi
else
    check "CAN interface" "skip"
    echo "  INFO: CAN HAT not detected — MCP2515 requires dtoverlay=mcp2515-can0 in config.txt"
fi

# ---------------------------------------------------------------------------
# [7] Network isolation — eth0 static address
# ---------------------------------------------------------------------------
echo ""
echo "[7] Network configuration"

ETH0_IP=$(ip -4 addr show eth0 2>/dev/null | awk '/inet /{print $2}' | cut -d/ -f1)
if [[ "$ETH0_IP" == "192.168.1.100" ]]; then
    check "eth0 has static IP 192.168.1.100" "pass"
elif [[ -n "$ETH0_IP" ]]; then
    check "eth0 has static IP" "skip"
    echo "  INFO: eth0 is ${ETH0_IP} — expected 192.168.1.100 (reconfigure via WebUI if needed)"
else
    check "eth0 has an IP address" "no IP assigned — check 10-eth0.network"
fi

WLAN_IP=$(ip -4 addr show wlan0 2>/dev/null | awk '/inet /{print $2}' | cut -d/ -f1 || echo "")
if [[ -n "$WLAN_IP" ]]; then
    check "wlan0 has IP (DHCP): ${WLAN_IP}" "pass"
else
    check "wlan0 has IP" "no IP — check WiFi credentials in WebUI"
fi

# ---------------------------------------------------------------------------
# [8] CODESYS gateway port (local reachability)
# ---------------------------------------------------------------------------
echo ""
echo "[8] CODESYS gateway port 1217"

if ss -tlnp 2>/dev/null | grep -q ":1217 "; then
    check "Gateway port 1217 is listening" "pass"
    if command -v nc &>/dev/null; then
        if nc -z -w2 127.0.0.1 1217 2>/dev/null; then
            check "Gateway port 1217 TCP connect (nc)" "pass"
        else
            check "Gateway port 1217 TCP connect" "connection refused"
        fi
    fi
else
    check "Gateway port 1217 listening" "not listening — CODESYS runtime not running"
fi

# ---------------------------------------------------------------------------
# [9] EtherCAT NIC presence (eth1 / USB-to-Ethernet)
# ---------------------------------------------------------------------------
echo ""
echo "[9] EtherCAT NIC"

EC_IFACE=$(ip link 2>/dev/null | awk -F': ' '/eth1/{print $2}' | head -1 || echo "")
if [[ -n "$EC_IFACE" ]]; then
    check "EtherCAT interface eth1 present" "pass"
    # eth1 should have NO IP (link-only for EtherCAT)
    ETH1_IP=$(ip -4 addr show eth1 2>/dev/null | awk '/inet /{print $2}' || echo "")
    if [[ -z "$ETH1_IP" ]]; then
        check "eth1 has no IP (correct — link-only for EtherCAT)" "pass"
    else
        check "eth1 has no IP" "eth1 has IP $ETH1_IP — should be link-only"
    fi
else
    check "EtherCAT interface eth1" "skip"
    echo "  INFO: Connect USB-to-Ethernet NIC for EtherCAT, then set MAC in WebUI Protocols page"
fi

# ---------------------------------------------------------------------------
# Results
# ---------------------------------------------------------------------------
echo ""
echo "=============================================="
echo "Results: ${PASS} passed, ${FAIL} failed, ${SKIP} skipped"
echo "=============================================="
echo ""
echo "Skipped tests indicate optional hardware not present or licensed features"
echo "not yet activated. This is expected for a fresh deployment."

if [[ "${FAIL}" -gt 0 ]]; then
    exit 1
fi
exit 0
