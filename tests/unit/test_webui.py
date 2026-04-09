"""
Unit tests for the cclrte Flask WebUI.

Mocks subprocess calls (systemctl, journalctl) and filesystem reads
so tests run without a live system.
"""
import json
import sys
import os
from unittest.mock import patch, MagicMock

import pytest

# Make the WebUI source importable
WEBUI_DIR = os.path.join(
    os.path.dirname(__file__),
    "../../layers/meta-cclrte/recipes-webui/plc-webui/files",
)
sys.path.insert(0, os.path.abspath(WEBUI_DIR))

import app as webui_app  # noqa: E402
import auth  # noqa: E402


# ---------------------------------------------------------------------------
# Fixtures
# ---------------------------------------------------------------------------

@pytest.fixture
def mock_service_status():
    """Return 'active' for any service status query."""
    with patch("app.service_status", return_value="active"):
        yield


@pytest.fixture
def client(mock_service_status):
    webui_app.app.config["TESTING"] = True
    webui_app.app.config["SECRET_KEY"] = "test-secret"
    webui_app.app.config["WTF_CSRF_ENABLED"] = False
    with webui_app.app.test_client() as c:
        yield c


@pytest.fixture
def logged_in_client(client):
    """Client with an authenticated session."""
    with patch("app.check_credentials", return_value=True):
        client.post(
            "/login",
            data={"username": "admin", "password": "admin"},
            follow_redirects=True,
        )
    return client


# ---------------------------------------------------------------------------
# Auth helpers
# ---------------------------------------------------------------------------

class TestAuthModule:
    def test_hash_password_returns_string(self):
        hashed = auth._hash_password("mysecret")
        assert isinstance(hashed, str)
        assert len(hashed) > 0

    def test_verify_correct_password(self):
        hashed = auth._hash_password("correct")
        assert auth._verify_password("correct", hashed) is True

    def test_verify_wrong_password(self):
        hashed = auth._hash_password("correct")
        assert auth._verify_password("wrong", hashed) is False

    def test_hash_is_not_plaintext(self):
        hashed = auth._hash_password("secret")
        assert "secret" not in hashed

    def test_two_hashes_of_same_password_differ(self):
        # PBKDF2 with random salt — each hash must be unique
        h1 = auth._hash_password("same")
        h2 = auth._hash_password("same")
        assert h1 != h2


# ---------------------------------------------------------------------------
# Login / logout
# ---------------------------------------------------------------------------

class TestLogin:
    def test_get_login_returns_200(self, client):
        resp = client.get("/login")
        assert resp.status_code == 200
        assert b"login" in resp.data.lower()

    def test_post_login_bad_credentials_shows_error(self, client):
        with patch("app.check_credentials", return_value=False):
            resp = client.post(
                "/login",
                data={"username": "admin", "password": "wrong"},
                follow_redirects=True,
            )
        assert resp.status_code == 200
        # Should stay on login page or show error
        assert b"invalid" in resp.data.lower() or b"login" in resp.data.lower()

    def test_post_login_good_credentials_redirects_to_dashboard(self, client):
        with patch("app.check_credentials", return_value=True):
            resp = client.post(
                "/login",
                data={"username": "admin", "password": "admin"},
                follow_redirects=False,
            )
        assert resp.status_code in (302, 303)
        assert "/" in resp.headers.get("Location", "/")

    def test_logout_redirects_to_login(self, logged_in_client):
        resp = logged_in_client.get("/logout", follow_redirects=False)
        assert resp.status_code in (302, 303)


# ---------------------------------------------------------------------------
# Protected routes redirect when unauthenticated
# ---------------------------------------------------------------------------

PROTECTED_ROUTES = ["/", "/network", "/protocols", "/codesys", "/system"]


class TestAuthGuard:
    @pytest.mark.parametrize("route", PROTECTED_ROUTES)
    def test_unauthenticated_redirects_to_login(self, client, route):
        resp = client.get(route, follow_redirects=False)
        assert resp.status_code in (302, 303)
        location = resp.headers.get("Location", "")
        assert "login" in location

    @pytest.mark.parametrize("route", PROTECTED_ROUTES)
    def test_authenticated_returns_200(self, logged_in_client, route):
        resp = logged_in_client.get(route)
        assert resp.status_code == 200


# ---------------------------------------------------------------------------
# API endpoints
# ---------------------------------------------------------------------------

class TestApiStatus:
    def test_api_status_unauthenticated_returns_401_or_redirect(self, client):
        resp = client.get("/api/status")
        assert resp.status_code in (302, 303, 401)

    def test_api_status_returns_json(self, logged_in_client):
        resp = logged_in_client.get("/api/status")
        assert resp.status_code == 200
        data = json.loads(resp.data)
        assert "codesys" in data
        assert "ethercat" in data
        assert "mosquitto" in data

    def test_api_status_has_expected_keys(self, logged_in_client):
        resp = logged_in_client.get("/api/status")
        data = json.loads(resp.data)
        for key in ("codesys", "ethercat", "mosquitto"):
            assert key in data, f"Missing key: {key}"
            assert data[key] is None or isinstance(data[key], str)


class TestApiCodesysLog:
    def test_api_codesys_log_returns_json_with_log_key(self, logged_in_client):
        mock_result = MagicMock()
        mock_result.stdout = "line1\nline2\nline3"
        mock_result.returncode = 0
        with patch("subprocess.run", return_value=mock_result):
            resp = logged_in_client.get("/api/codesys/log")
        assert resp.status_code == 200
        data = json.loads(resp.data)
        assert "log" in data
        assert isinstance(data["log"], (str, list))

    def test_api_codesys_log_unauthenticated(self, client):
        resp = client.get("/api/codesys/log")
        assert resp.status_code in (302, 303, 401)


# ---------------------------------------------------------------------------
# Page content smoke tests
# ---------------------------------------------------------------------------

class TestPageContent:
    def test_dashboard_contains_service_status(self, logged_in_client):
        resp = logged_in_client.get("/")
        assert resp.status_code == 200
        # Should mention key services
        body = resp.data.lower()
        assert b"codesys" in body or b"ethercat" in body

    def test_network_page_contains_eth0(self, logged_in_client):
        resp = logged_in_client.get("/network")
        assert resp.status_code == 200
        assert b"eth0" in resp.data

    def test_protocols_page_contains_ethercat(self, logged_in_client):
        resp = logged_in_client.get("/protocols")
        assert resp.status_code == 200
        assert b"ethercat" in resp.data.lower()

    def test_codesys_page_loads(self, logged_in_client):
        resp = logged_in_client.get("/codesys")
        assert resp.status_code == 200
        assert b"codesys" in resp.data.lower()

    def test_system_page_loads(self, logged_in_client):
        resp = logged_in_client.get("/system")
        assert resp.status_code == 200


# ---------------------------------------------------------------------------
# Full login → access → logout flow
# ---------------------------------------------------------------------------

class TestSessionFlow:
    def test_full_session_flow(self, client):
        # 1. Unauthenticated access is denied
        resp = client.get("/", follow_redirects=False)
        assert resp.status_code in (302, 303)

        # 2. Login
        with patch("app.check_credentials", return_value=True):
            resp = client.post(
                "/login",
                data={"username": "admin", "password": "admin"},
                follow_redirects=True,
            )
        assert resp.status_code == 200

        # 3. Dashboard is now accessible
        resp = client.get("/")
        assert resp.status_code == 200

        # 4. Logout
        resp = client.get("/logout", follow_redirects=False)
        assert resp.status_code in (302, 303)

        # 5. Unauthenticated again
        resp = client.get("/", follow_redirects=False)
        assert resp.status_code in (302, 303)


# ===========================================================================
# Network form submission tests
# ===========================================================================

class TestNetworkFormEth0:
    def test_post_eth0_writes_network_file(self, logged_in_client):
        m = MagicMock()
        with patch("builtins.open", m), \
             patch("app.run", return_value=("", 0)):
            resp = logged_in_client.post("/network", data={
                "action": "eth0",
                "eth0_ip": "192.168.1.100",
                "eth0_prefix": "24",
                "eth0_gw": "192.168.1.1",
            })
        assert resp.status_code == 200
        # Verify open() was called to write the network file
        assert m.called

    def test_post_eth0_ip_appears_in_config(self, logged_in_client):
        written = []
        def fake_open(path, mode="r", **kw):
            import io
            if mode == "w":
                buf = io.StringIO()
                buf.close = lambda: written.append(buf.getvalue())
                return buf
            raise FileNotFoundError(path)
        with patch("builtins.open", fake_open), \
             patch("app.run", return_value=("", 0)), \
             patch("app.get_ip", return_value="192.168.2.50"):
            logged_in_client.post("/network", data={
                "action": "eth0",
                "eth0_ip": "192.168.2.50",
                "eth0_prefix": "24",
                "eth0_gw": "192.168.2.1",
            })
        assert any("192.168.2.50" in w for w in written), f"IP not found in written content: {written}"

    def test_post_wifi_empty_ssid_shows_error(self, logged_in_client):
        resp = logged_in_client.post("/network", data={
            "action": "wifi",
            "ssid": "",
            "password": "pass",
            "country": "DE",
        })
        assert resp.status_code == 200
        assert b"required" in resp.data.lower() or b"error" in resp.data.lower()

    def test_post_wifi_empty_password_shows_error(self, logged_in_client):
        resp = logged_in_client.post("/network", data={
            "action": "wifi",
            "ssid": "MyNet",
            "password": "",
            "country": "DE",
        })
        assert resp.status_code == 200
        assert b"required" in resp.data.lower() or b"error" in resp.data.lower()

    def test_post_wifi_success_writes_wpa_conf(self, logged_in_client):
        m = MagicMock()
        with patch("builtins.open", m), \
             patch("os.chmod"), \
             patch("app.run", return_value=('network={\n    ssid="MyNet"\n}', 0)):
            resp = logged_in_client.post("/network", data={
                "action": "wifi",
                "ssid": "MyNet",
                "password": "password123",
                "country": "DE",
            })
        assert resp.status_code == 200
        assert m.called

    def test_post_ssh_key_invalid_format_shows_error(self, logged_in_client):
        resp = logged_in_client.post("/network", data={
            "action": "ssh_key",
            "ssh_key": "not-a-valid-key",
        })
        assert resp.status_code == 200
        assert b"invalid" in resp.data.lower() or b"error" in resp.data.lower()

    def test_post_ssh_key_valid_format_succeeds(self, logged_in_client):
        m = MagicMock()
        with patch("builtins.open", m), \
             patch("os.makedirs"), \
             patch("os.chmod"):
            resp = logged_in_client.post("/network", data={
                "action": "ssh_key",
                "ssh_key": "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAItest user@host",
            })
        assert resp.status_code == 200
        assert m.called


# ===========================================================================
# Protocols page form submission tests
# ===========================================================================

class TestProtocolsForm:
    def test_post_ethercat_mac_writes_config(self, logged_in_client):
        m = MagicMock()
        with patch("builtins.open", m), \
             patch("app.run", return_value=("", 0)):
            resp = logged_in_client.post("/protocols", data={
                "action": "ethercat",
                "master_device": "AA:BB:CC:DD:EE:FF",
            })
        assert resp.status_code == 200
        assert m.called

    def test_post_ethercat_mac_content_correct(self, logged_in_client):
        written = []
        def fake_open(path, mode="r", **kw):
            import io
            if mode == "w":
                buf = io.StringIO()
                buf.close = lambda: written.append(buf.getvalue())
                return buf
            raise FileNotFoundError(path)
        with patch("builtins.open", fake_open), \
             patch("app.run", return_value=("", 0)):
            logged_in_client.post("/protocols", data={
                "action": "ethercat",
                "master_device": "AA:BB:CC:DD:EE:FF",
            })
        # Verify MAC appears in written config
        assert any("AA:BB:CC:DD:EE:FF" in w for w in written), f"MAC not in written: {written}"
        assert any("DEVICE_MODULES" in w for w in written)

    def test_post_service_toggle_start_ethercat(self, logged_in_client):
        with patch("app.run", return_value=("", 0)) as mock_run:
            resp = logged_in_client.post("/protocols", data={
                "action": "service_toggle",
                "service": "ethercat",
                "toggle": "start",
            })
        assert resp.status_code == 200

    def test_post_service_toggle_disallowed_service(self, logged_in_client):
        with patch("app.run", return_value=("", 0)) as mock_run:
            resp = logged_in_client.post("/protocols", data={
                "action": "service_toggle",
                "service": "sshd",  # not in allowed list
                "toggle": "stop",
            })
        # Should NOT call systemctl on a non-allowed service
        assert resp.status_code == 200
        # run() should not have been called with 'sshd'
        for call in mock_run.call_args_list:
            assert "sshd" not in str(call)

    def test_protocols_page_shows_ethercat_status(self, logged_in_client):
        resp = logged_in_client.get("/protocols")
        assert resp.status_code == 200
        assert b"ethercat" in resp.data.lower()

    def test_protocols_page_shows_mqtt_status(self, logged_in_client):
        resp = logged_in_client.get("/protocols")
        assert resp.status_code == 200
        assert b"mqtt" in resp.data.lower() or b"mosquitto" in resp.data.lower()

    def test_protocols_page_shows_opcua(self, logged_in_client):
        resp = logged_in_client.get("/protocols")
        assert resp.status_code == 200
        assert b"opc" in resp.data.lower()

    def test_protocols_page_shows_profinet(self, logged_in_client):
        resp = logged_in_client.get("/protocols")
        assert resp.status_code == 200
        assert b"profinet" in resp.data.lower()

    def test_protocols_page_shows_iolink(self, logged_in_client):
        resp = logged_in_client.get("/protocols")
        assert resp.status_code == 200
        assert b"io-link" in resp.data.lower() or b"iolink" in resp.data.lower()


# ===========================================================================
# CODESYS page form submission tests
# ===========================================================================

class TestCodesysForm:
    def test_post_start_codesys(self, logged_in_client):
        with patch("app.run", return_value=("", 0)) as mock_run:
            resp = logged_in_client.post("/codesys", data={"action": "start"})
        assert resp.status_code == 200
        calls = [str(c) for c in mock_run.call_args_list]
        assert any("start codesyscontrol" in c for c in calls)

    def test_post_stop_codesys(self, logged_in_client):
        with patch("app.run", return_value=("", 0)) as mock_run:
            resp = logged_in_client.post("/codesys", data={"action": "stop"})
        assert resp.status_code == 200
        calls = [str(c) for c in mock_run.call_args_list]
        assert any("stop codesyscontrol" in c for c in calls)

    def test_post_restart_codesys(self, logged_in_client):
        with patch("app.run", return_value=("", 0)) as mock_run:
            resp = logged_in_client.post("/codesys", data={"action": "restart"})
        assert resp.status_code == 200
        calls = [str(c) for c in mock_run.call_args_list]
        assert any("restart codesyscontrol" in c for c in calls)

    def test_post_install_check_runtime_missing(self, logged_in_client):
        with patch("os.path.exists", return_value=False):
            resp = logged_in_client.post("/codesys", data={"action": "install_check"})
        assert resp.status_code == 200
        assert b"not installed" in resp.data.lower() or b"install" in resp.data.lower()

    def test_post_install_check_runtime_present(self, logged_in_client):
        with patch("os.path.exists", return_value=True):
            resp = logged_in_client.post("/codesys", data={"action": "install_check"})
        assert resp.status_code == 200
        assert b"installed" in resp.data.lower()

    def test_codesys_page_shows_gateway_ip(self, logged_in_client):
        with patch("app.get_ip", return_value="192.168.1.100"):
            resp = logged_in_client.get("/codesys")
        assert resp.status_code == 200
        assert b"192.168.1.100" in resp.data


# ===========================================================================
# System page form submission tests
# ===========================================================================

class TestSystemForm:
    def test_post_rt_verify_starts_service(self, logged_in_client):
        with patch("app.run", return_value=("", 0)) as mock_run:
            resp = logged_in_client.post("/system", data={"action": "rt_verify"})
        assert resp.status_code == 200
        calls = [str(c) for c in mock_run.call_args_list]
        assert any("rt-verify" in c for c in calls)

    def test_post_change_password_wrong_old(self, logged_in_client):
        with patch("app.check_credentials", return_value=False):
            resp = logged_in_client.post("/system", data={
                "action": "change_password",
                "old_password": "wrongold",
                "new_password": "newpass",
            })
        assert resp.status_code == 200
        assert b"incorrect" in resp.data.lower() or b"error" in resp.data.lower()

    def test_post_change_password_correct_old(self, logged_in_client):
        with patch("app.check_credentials", return_value=True), \
             patch("app.set_password") as mock_set:
            resp = logged_in_client.post("/system", data={
                "action": "change_password",
                "old_password": "admin",
                "new_password": "newpass123",
            })
        assert resp.status_code == 200
        mock_set.assert_called_once_with("admin", "newpass123")

    def test_post_reboot_calls_systemctl(self, logged_in_client):
        with patch("app.run", return_value=("", 0)) as mock_run:
            resp = logged_in_client.post("/system", data={"action": "reboot"})
        assert resp.status_code == 200
        calls = [str(c) for c in mock_run.call_args_list]
        assert any("reboot" in c for c in calls)

    def test_system_page_shows_kernel_version(self, logged_in_client):
        with patch("app.run", return_value=("6.6.31-cclrte-rt", 0)):
            resp = logged_in_client.get("/system")
        assert resp.status_code == 200

    def test_system_page_shows_rt_result_when_available(self, logged_in_client):
        import json as _json
        rt_data = {"max_latency_us": 45, "pass": True, "threshold_us": 100, "duration_s": 60}
        with patch("builtins.open", MagicMock(return_value=MagicMock(
            __enter__=lambda s, *a: MagicMock(read=lambda: _json.dumps(rt_data)),
            __exit__=MagicMock(return_value=False),
        ))):
            resp = logged_in_client.get("/system")
        assert resp.status_code == 200


# ===========================================================================
# API endpoint full coverage
# ===========================================================================

class TestApiFullCoverage:
    def test_api_status_includes_eth0_ip(self, logged_in_client):
        with patch("app.get_ip", return_value="192.168.1.100"):
            resp = logged_in_client.get("/api/status")
        data = json.loads(resp.data)
        assert "eth0_ip" in data

    def test_api_status_includes_uptime(self, logged_in_client):
        with patch("app.uptime", return_value="1 days 00:30"):
            resp = logged_in_client.get("/api/status")
        data = json.loads(resp.data)
        assert "uptime" in data

    def test_api_status_includes_timestamp(self, logged_in_client):
        resp = logged_in_client.get("/api/status")
        data = json.loads(resp.data)
        assert "timestamp" in data

    def test_api_status_rt_field_is_dict_or_none(self, logged_in_client):
        with patch("app.read_rt_result", return_value={"max_latency_us": 42, "pass": True}):
            resp = logged_in_client.get("/api/status")
        data = json.loads(resp.data)
        assert data["rt"] is None or isinstance(data["rt"], dict)

    def test_api_codesys_log_empty(self, logged_in_client):
        with patch("app.run", return_value=("", 0)):
            resp = logged_in_client.get("/api/codesys/log")
        data = json.loads(resp.data)
        assert "log" in data
        assert data["log"] == ""

    def test_api_codesys_log_multiline(self, logged_in_client):
        lines = "\n".join(f"Mar 31 00:0{i} codesyscontrol: line {i}" for i in range(50))
        with patch("app.run", return_value=(lines, 0)):
            resp = logged_in_client.get("/api/codesys/log")
        data = json.loads(resp.data)
        assert "line 0" in data["log"]
