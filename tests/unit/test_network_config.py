"""
Unit tests for network configuration logic.

Tests site.conf parsing, systemd-networkd file generation, and
wpa_supplicant config generation. All functions are pure Python —
no subprocess, no filesystem access required.
"""
import ipaddress
import re
import textwrap

import pytest


# ---------------------------------------------------------------------------
# Pure-Python implementations of the network config logic
# (mirrors network-firstboot.sh logic)
# ---------------------------------------------------------------------------

def parse_site_conf(content: str) -> dict:
    """Parse shell-style KEY="VALUE" lines from site.conf content."""
    config = {}
    for line in content.splitlines():
        line = line.strip()
        if not line or line.startswith("#"):
            continue
        if "=" not in line:
            continue
        key, _, value = line.partition("=")
        # Strip surrounding quotes
        value = value.strip().strip('"').strip("'")
        config[key.strip()] = value
    return config


def validate_ip(ip: str) -> bool:
    """Return True if ip is a valid IPv4 address."""
    try:
        ipaddress.IPv4Address(ip)
        return True
    except ValueError:
        return False


def validate_prefix(prefix: str) -> bool:
    """Return True if prefix is a valid IPv4 prefix length (0–32)."""
    try:
        p = int(prefix)
        return 0 <= p <= 32
    except ValueError:
        return False


def validate_hostname(hostname: str) -> bool:
    """Return True if hostname is a valid RFC-1123 hostname."""
    if not hostname or len(hostname) > 253:
        return False
    pattern = re.compile(r"^[a-zA-Z0-9]([a-zA-Z0-9\-]{0,61}[a-zA-Z0-9])?$")
    return bool(pattern.match(hostname))


def generate_eth0_network(ip: str, prefix: str, gateway: str) -> str:
    """Generate systemd-networkd .network file content for eth0 (static)."""
    return textwrap.dedent(f"""\
        [Match]
        Name=eth0

        [Network]
        Address={ip}/{prefix}
        Gateway={gateway}
        DNS=8.8.8.8
        WakeOnLan=off
    """)


def generate_wlan0_network_dhcp() -> str:
    """Generate systemd-networkd .network file for wlan0 (DHCP)."""
    return textwrap.dedent("""\
        [Match]
        Name=wlan0

        [Network]
        DHCP=yes
        IgnoreCarrierLoss=3s
    """)


def generate_wlan0_network_static(ip: str, prefix: str) -> str:
    """Generate systemd-networkd .network file for wlan0 (static)."""
    return textwrap.dedent(f"""\
        [Match]
        Name=wlan0

        [Network]
        Address={ip}/{prefix}
        IgnoreCarrierLoss=3s
    """)


def generate_wpa_supplicant(ssid: str, password: str, country: str) -> str:
    """Generate wpa_supplicant.conf content."""
    return textwrap.dedent(f"""\
        ctrl_interface=DIR=/var/run/wpa_supplicant GROUP=netdev
        update_config=1
        country={country}

        network={{
            ssid="{ssid}"
            psk="{password}"
            key_mgmt=WPA-PSK
        }}
    """)


# ---------------------------------------------------------------------------
# Tests: parse_site_conf
# ---------------------------------------------------------------------------

SAMPLE_CONF = """\
# cclrte site configuration
WIFI_SSID="MyNetwork"
WIFI_PASSWORD="s3cret!"
WIFI_COUNTRY="DE"
SSH_AUTHORIZED_KEY="ssh-ed25519 AAAAC3Nz user@host"
ETH0_IP="192.168.1.100"
ETH0_PREFIX="24"
ETH0_GW="192.168.1.1"
WLAN_IP=""
DEVICE_HOSTNAME="cclrte-plc"
"""


class TestSiteConfParsing:
    def test_parses_wifi_ssid(self):
        cfg = parse_site_conf(SAMPLE_CONF)
        assert cfg["WIFI_SSID"] == "MyNetwork"

    def test_parses_wifi_password(self):
        cfg = parse_site_conf(SAMPLE_CONF)
        assert cfg["WIFI_PASSWORD"] == "s3cret!"

    def test_parses_wifi_country(self):
        cfg = parse_site_conf(SAMPLE_CONF)
        assert cfg["WIFI_COUNTRY"] == "DE"

    def test_parses_eth0_ip(self):
        cfg = parse_site_conf(SAMPLE_CONF)
        assert cfg["ETH0_IP"] == "192.168.1.100"

    def test_parses_eth0_prefix(self):
        cfg = parse_site_conf(SAMPLE_CONF)
        assert cfg["ETH0_PREFIX"] == "24"

    def test_parses_eth0_gateway(self):
        cfg = parse_site_conf(SAMPLE_CONF)
        assert cfg["ETH0_GW"] == "192.168.1.1"

    def test_parses_empty_wlan_ip(self):
        cfg = parse_site_conf(SAMPLE_CONF)
        assert cfg["WLAN_IP"] == ""

    def test_parses_hostname(self):
        cfg = parse_site_conf(SAMPLE_CONF)
        assert cfg["DEVICE_HOSTNAME"] == "cclrte-plc"

    def test_comments_are_ignored(self):
        cfg = parse_site_conf(SAMPLE_CONF)
        assert "# cclrte site configuration" not in cfg

    def test_missing_optional_field_not_in_dict(self):
        cfg = parse_site_conf("WIFI_SSID=\"test\"\n")
        assert "WLAN_IP" not in cfg

    def test_empty_content_returns_empty_dict(self):
        cfg = parse_site_conf("")
        assert cfg == {}

    def test_single_quotes_stripped(self):
        cfg = parse_site_conf("KEY='value'\n")
        assert cfg["KEY"] == "value"


# ---------------------------------------------------------------------------
# Tests: validate_ip
# ---------------------------------------------------------------------------

class TestValidateIP:
    @pytest.mark.parametrize("ip", [
        "192.168.1.100",
        "10.0.0.1",
        "172.16.0.1",
        "0.0.0.0",
        "255.255.255.255",
    ])
    def test_valid_ips(self, ip):
        assert validate_ip(ip) is True

    @pytest.mark.parametrize("ip", [
        "256.0.0.1",
        "192.168.1",
        "not-an-ip",
        "",
        "192.168.1.1.1",
        "::1",
    ])
    def test_invalid_ips(self, ip):
        assert validate_ip(ip) is False


# ---------------------------------------------------------------------------
# Tests: validate_prefix
# ---------------------------------------------------------------------------

class TestValidatePrefix:
    @pytest.mark.parametrize("prefix", ["0", "1", "24", "30", "32"])
    def test_valid_prefixes(self, prefix):
        assert validate_prefix(prefix) is True

    @pytest.mark.parametrize("prefix", ["-1", "33", "abc", ""])
    def test_invalid_prefixes(self, prefix):
        assert validate_prefix(prefix) is False


# ---------------------------------------------------------------------------
# Tests: validate_hostname
# ---------------------------------------------------------------------------

class TestValidateHostname:
    @pytest.mark.parametrize("hostname", [
        "cclrte-plc",
        "plc1",
        "my-machine-01",
        "RPi4",
    ])
    def test_valid_hostnames(self, hostname):
        assert validate_hostname(hostname) is True

    @pytest.mark.parametrize("hostname", [
        "",
        "-invalid",
        "invalid-",
        "has space",
        "a" * 254,
        "has.dot",
    ])
    def test_invalid_hostnames(self, hostname):
        assert validate_hostname(hostname) is False


# ---------------------------------------------------------------------------
# Tests: generate_eth0_network
# ---------------------------------------------------------------------------

class TestEth0NetworkGeneration:
    def test_contains_match_section(self):
        out = generate_eth0_network("192.168.1.100", "24", "192.168.1.1")
        assert "[Match]" in out
        assert "Name=eth0" in out

    def test_contains_static_address(self):
        out = generate_eth0_network("192.168.1.100", "24", "192.168.1.1")
        assert "Address=192.168.1.100/24" in out

    def test_contains_gateway(self):
        out = generate_eth0_network("10.0.0.5", "16", "10.0.0.1")
        assert "Gateway=10.0.0.1" in out

    def test_no_dhcp_directive(self):
        out = generate_eth0_network("192.168.1.100", "24", "192.168.1.1")
        assert "DHCP=yes" not in out

    def test_wake_on_lan_off(self):
        out = generate_eth0_network("192.168.1.100", "24", "192.168.1.1")
        assert "WakeOnLan=off" in out


# ---------------------------------------------------------------------------
# Tests: generate_wlan0_network
# ---------------------------------------------------------------------------

class TestWlan0NetworkGeneration:
    def test_dhcp_mode_has_dhcp_yes(self):
        out = generate_wlan0_network_dhcp()
        assert "DHCP=yes" in out
        assert "Name=wlan0" in out

    def test_static_mode_has_address(self):
        out = generate_wlan0_network_static("10.0.0.50", "24")
        assert "Address=10.0.0.50/24" in out
        assert "DHCP=yes" not in out

    def test_empty_wlan_ip_leads_to_dhcp(self):
        cfg = parse_site_conf("WLAN_IP=\"\"\n")
        wlan_ip = cfg.get("WLAN_IP", "")
        if wlan_ip:
            prefix = cfg.get("WLAN_PREFIX", "24")
            out = generate_wlan0_network_static(wlan_ip, prefix)
        else:
            out = generate_wlan0_network_dhcp()
        assert "DHCP=yes" in out


# ---------------------------------------------------------------------------
# Tests: generate_wpa_supplicant
# ---------------------------------------------------------------------------

class TestWpaSupplicantGeneration:
    def test_contains_ssid(self):
        out = generate_wpa_supplicant("MyNet", "pass123", "DE")
        assert 'ssid="MyNet"' in out

    def test_contains_psk(self):
        out = generate_wpa_supplicant("MyNet", "pass123", "DE")
        assert 'psk="pass123"' in out

    def test_contains_country(self):
        out = generate_wpa_supplicant("MyNet", "pass123", "US")
        assert "country=US" in out

    def test_contains_wpa_psk_key_mgmt(self):
        out = generate_wpa_supplicant("MyNet", "pass123", "DE")
        assert "key_mgmt=WPA-PSK" in out

    def test_ssid_with_special_chars(self):
        out = generate_wpa_supplicant("My Network 2.4GHz", "p@$$w0rd!", "GB")
        assert 'ssid="My Network 2.4GHz"' in out
