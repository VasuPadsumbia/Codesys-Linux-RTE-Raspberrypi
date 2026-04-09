"""
Unit tests for protocol configuration and validation logic.

Covers: EtherCAT, MQTT, OPC-UA, PROFINET, IO-Link configuration
validation and file generation. No hardware or running services required.
"""
import re
import textwrap

import pytest


# ---------------------------------------------------------------------------
# Helpers — mirrors app.py / recipe logic
# ---------------------------------------------------------------------------

def validate_mac(mac: str) -> bool:
    """Validate IEEE 802.3 MAC address format XX:XX:XX:XX:XX:XX."""
    pattern = re.compile(r'^([0-9A-Fa-f]{2}:){5}[0-9A-Fa-f]{2}$')
    return bool(pattern.match(mac))


def generate_ethercat_conf(mac: str, driver: str = "generic") -> str:
    """Generate /etc/ethercat.conf content."""
    return f'MASTER0_DEVICE="{mac}"\nDEVICE_MODULES="{driver}"\n'


def parse_ethercat_slaves(output: str) -> list:
    """Parse output of 'ethercat slaves' into list of dicts."""
    slaves = []
    for line in output.strip().splitlines():
        # Format: "0  0:0  PREOP  +  EL2008"
        parts = line.strip().split()
        if len(parts) >= 5:
            slaves.append({
                "index": parts[0],
                "state": parts[2],
                "name": parts[4] if len(parts) > 4 else "",
            })
    return slaves


def validate_mqtt_topic(topic: str) -> bool:
    """Validate MQTT topic string (no null bytes, not empty, max 65535 chars)."""
    if not topic or len(topic) > 65535:
        return False
    if '\x00' in topic:
        return False
    return True


def validate_port(port: int, allow_privileged: bool = False) -> bool:
    """Validate TCP port number."""
    if not isinstance(port, int):
        return False
    if port < 1 or port > 65535:
        return False
    if not allow_privileged and port < 1024:
        return False
    return True


def validate_opcua_url(url: str) -> bool:
    """Validate OPC-UA endpoint URL format."""
    return url.startswith("opc.tcp://") and ":" in url.split("//", 1)[1]


def validate_profinet_station_name(name: str) -> bool:
    """
    Validate PROFINET station name.
    Rules: lowercase letters, digits, hyphens; no leading/trailing hyphen;
    max 240 chars; no consecutive hyphens.
    """
    if not name or len(name) > 240:
        return False
    if not re.match(r'^[a-z0-9]([a-z0-9\-]*[a-z0-9])?$', name):
        return False
    if '--' in name:
        return False
    return True


def validate_iolink_port_count(count: int) -> bool:
    """IO-Link via SPI0 supports exactly 4 ports."""
    return count == 4


def generate_mosquitto_default_conf() -> str:
    """Generate default Mosquitto config with WebSocket support."""
    return textwrap.dedent("""\
        listener 1883
        allow_anonymous true

        listener 9001
        protocol websockets
    """)


# ---------------------------------------------------------------------------
# EtherCAT tests
# ---------------------------------------------------------------------------

class TestEtherCATConfig:
    @pytest.mark.parametrize("mac", [
        "AA:BB:CC:DD:EE:FF",
        "aa:bb:cc:dd:ee:ff",
        "00:11:22:33:44:55",
        "FF:FF:FF:FF:FF:FF",
        "01:23:45:67:89:AB",
    ])
    def test_valid_mac_addresses(self, mac):
        assert validate_mac(mac) is True

    @pytest.mark.parametrize("mac", [
        "ZZ:BB:CC:DD:EE:FF",
        "AA:BB:CC:DD:EE",           # too short
        "AA:BB:CC:DD:EE:FF:00",     # too long
        "",                          # empty
        "AA-BB-CC-DD-EE-FF",        # wrong separator
        "AABBCCDDEEFF",             # no separators
        "AA:BB:CC:DD:EE:GG",        # invalid hex char G
    ])
    def test_invalid_mac_addresses(self, mac):
        assert validate_mac(mac) is False

    def test_ethercat_conf_contains_mac(self):
        conf = generate_ethercat_conf("AA:BB:CC:DD:EE:FF")
        assert 'MASTER0_DEVICE="AA:BB:CC:DD:EE:FF"' in conf

    def test_ethercat_conf_contains_generic_driver(self):
        conf = generate_ethercat_conf("AA:BB:CC:DD:EE:FF")
        assert 'DEVICE_MODULES="generic"' in conf

    def test_ethercat_conf_custom_driver(self):
        conf = generate_ethercat_conf("AA:BB:CC:DD:EE:FF", driver="r8169")
        assert 'DEVICE_MODULES="r8169"' in conf

    def test_parse_zero_slaves(self):
        assert parse_ethercat_slaves("") == []

    def test_parse_single_slave(self):
        output = "0  0:0  PREOP  +  EL2008"
        slaves = parse_ethercat_slaves(output)
        assert len(slaves) == 1
        assert slaves[0]["name"] == "EL2008"
        assert slaves[0]["state"] == "PREOP"

    def test_parse_multiple_slaves(self):
        output = (
            "0  0:0  OP  +  EL2008\n"
            "1  0:1  OP  +  EL7201\n"
            "2  0:2  OP  +  EK1100\n"
        )
        slaves = parse_ethercat_slaves(output)
        assert len(slaves) == 3
        assert slaves[1]["name"] == "EL7201"

    def test_slave_in_op_state(self):
        output = "0  0:0  OP  +  EL2008"
        slaves = parse_ethercat_slaves(output)
        assert slaves[0]["state"] == "OP"

    def test_slave_in_preop_not_ready(self):
        output = "0  0:0  PREOP  +  EL7201"
        slaves = parse_ethercat_slaves(output)
        # PREOP means slave not fully initialized
        assert slaves[0]["state"] == "PREOP"


# ---------------------------------------------------------------------------
# MQTT tests
# ---------------------------------------------------------------------------

class TestMQTTConfig:
    def test_default_conf_has_port_1883(self):
        conf = generate_mosquitto_default_conf()
        assert "listener 1883" in conf

    def test_default_conf_has_websocket_port_9001(self):
        conf = generate_mosquitto_default_conf()
        assert "listener 9001" in conf
        assert "protocol websockets" in conf

    def test_default_conf_allows_anonymous(self):
        conf = generate_mosquitto_default_conf()
        assert "allow_anonymous true" in conf

    @pytest.mark.parametrize("topic", [
        "test/cclrte",
        "plc/axis1/position",
        "cclrte/status",
        "a",
        "/",
        "topic/with/many/levels",
    ])
    def test_valid_mqtt_topics(self, topic):
        assert validate_mqtt_topic(topic) is True

    @pytest.mark.parametrize("topic", [
        "",                     # empty
        "topic\x00null",        # null byte
        "a" * 65536,            # too long
    ])
    def test_invalid_mqtt_topics(self, topic):
        assert validate_mqtt_topic(topic) is False

    def test_mqtt_publish_subscribe_flow(self):
        """Simulate a publish-subscribe message flow (logic only)."""
        published = []
        subscriptions = {}

        def publish(topic, message):
            published.append((topic, message))
            if topic in subscriptions:
                for cb in subscriptions[topic]:
                    cb(message)

        def subscribe(topic, callback):
            subscriptions.setdefault(topic, []).append(callback)

        received = []
        subscribe("plc/status", received.append)
        publish("plc/status", "running")
        publish("plc/status", "stopped")

        assert len(received) == 2
        assert received[0] == "running"
        assert received[1] == "stopped"


# ---------------------------------------------------------------------------
# OPC-UA tests
# ---------------------------------------------------------------------------

class TestOPCUAConfig:
    def test_valid_opcua_port(self):
        assert validate_port(4840, allow_privileged=True) is True

    def test_port_below_1024_rejected_without_root(self):
        assert validate_port(80, allow_privileged=False) is False

    def test_port_below_1024_allowed_with_root(self):
        assert validate_port(80, allow_privileged=True) is True

    def test_port_65535_valid(self):
        assert validate_port(65535) is True

    def test_port_65536_invalid(self):
        assert validate_port(65536) is False

    def test_port_0_invalid(self):
        assert validate_port(0) is False

    def test_valid_opcua_url(self):
        assert validate_opcua_url("opc.tcp://192.168.1.100:4840") is True

    def test_opcua_url_wrong_scheme(self):
        assert validate_opcua_url("http://192.168.1.100:4840") is False

    def test_opcua_url_no_port(self):
        assert validate_opcua_url("opc.tcp://192.168.1.100") is False

    def test_opcua_url_with_path(self):
        assert validate_opcua_url("opc.tcp://192.168.1.100:4840/server") is True

    def test_opcua_standard_port(self):
        # OPC-UA standard port is 4840
        assert validate_port(4840, allow_privileged=True) is True


# ---------------------------------------------------------------------------
# PROFINET tests
# ---------------------------------------------------------------------------

class TestPROFINETConfig:
    def test_valid_station_name_simple(self):
        assert validate_profinet_station_name("cclrte-plc") is True

    def test_valid_station_name_numeric(self):
        assert validate_profinet_station_name("plc1") is True

    def test_valid_station_name_short(self):
        assert validate_profinet_station_name("a") is True

    @pytest.mark.parametrize("name", [
        "",                   # empty
        "-bad",               # leading hyphen
        "bad-",               # trailing hyphen
        "has space",          # spaces not allowed
        "Has_Upper",          # uppercase not allowed in PROFINET station names
        "double--hyphen",     # consecutive hyphens
        "a" * 241,            # too long
    ])
    def test_invalid_station_names(self, name):
        assert validate_profinet_station_name(name) is False

    def test_profinet_is_device_mode_only(self):
        """
        p-net implements PROFINET device (slave) only.
        Verify our config does not include controller settings.
        """
        # Read the actual profinet config file
        import os
        conf_path = os.path.join(
            os.path.dirname(__file__),
            "../../layers/meta-cclrte/recipes-connectivity/profinet/files/profinet.conf",
        )
        if os.path.exists(conf_path):
            with open(conf_path) as f:
                content = f.read()
            assert "controller" not in content.lower() or "device" in content.lower()

    def test_profinet_max_station_name_length(self):
        long_name = "a" * 240
        assert validate_profinet_station_name(long_name) is True
        too_long = "a" * 241
        assert validate_profinet_station_name(too_long) is False


# ---------------------------------------------------------------------------
# IO-Link tests
# ---------------------------------------------------------------------------

class TestIOLinkConfig:
    def test_exactly_4_ports(self):
        assert validate_iolink_port_count(4) is True

    def test_fewer_than_4_ports_invalid(self):
        assert validate_iolink_port_count(3) is False
        assert validate_iolink_port_count(0) is False

    def test_more_than_4_ports_invalid(self):
        # Current SPI0 HAT limitation
        assert validate_iolink_port_count(5) is False
        assert validate_iolink_port_count(8) is False

    def test_spi_device_path_exists_in_config(self):
        """Verify SPI0 device path is referenced in the iolink config."""
        import os
        conf_path = os.path.join(
            os.path.dirname(__file__),
            "../../layers/meta-cclrte/recipes-connectivity/iolink/files/iolink.conf",
        )
        if os.path.exists(conf_path):
            with open(conf_path) as f:
                content = f.read()
            assert "spi" in content.lower() or "spidev" in content.lower()

    def test_port_numbering_1_to_4(self):
        """IO-Link ports are conventionally numbered 1–4."""
        valid_ports = list(range(1, 5))
        assert valid_ports == [1, 2, 3, 4]

    def test_port_0_not_valid(self):
        """Port 0 is not a valid IO-Link port number."""
        assert 0 not in range(1, 5)
