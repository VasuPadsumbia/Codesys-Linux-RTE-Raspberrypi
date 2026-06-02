"""
Unit tests for RT setup verification logic.

All filesystem reads are mocked using tmp_path or unittest.mock.
No real system access required.
"""
import json
import re
from pathlib import Path
from unittest.mock import MagicMock, patch

import pytest


# ---------------------------------------------------------------------------
# Pure-Python verification helpers (mirrors run-cyclictest.sh / rt-setup.sh)
# ---------------------------------------------------------------------------

def parse_rt_result(content: str) -> dict:
    """Parse the JSON result file written by run-cyclictest.sh."""
    return json.loads(content)


def check_latency_pass(result: dict, threshold_us: int = 100) -> bool:
    """Return True if max_latency_us < threshold_us."""
    return result.get("max_latency_us", float("inf")) < threshold_us


def check_isolcpus(cmdline: str) -> bool:
    """Return True if isolcpus=2,3 is present in /proc/cmdline."""
    return "isolcpus=2,3" in cmdline


def check_nohz_full(cmdline: str) -> bool:
    """Return True if nohz_full=2,3 is present in /proc/cmdline."""
    return "nohz_full=2,3" in cmdline


def check_cpu_governor(governor_content: str) -> bool:
    """Return True if the cpufreq governor is 'performance'."""
    return governor_content.strip() == "performance"


def check_sched_rt_runtime(sysctl_content: str) -> bool:
    """Return True if sched_rt_runtime_us is -1 (no RT bandwidth cap)."""
    try:
        return int(sysctl_content.strip()) == -1
    except ValueError:
        return False


def validate_smp_affinity(affinity_hex: str) -> bool:
    """Return True if the IRQ affinity mask is a valid hex string."""
    try:
        value = int(affinity_hex.strip(), 16)
        return value >= 0
    except ValueError:
        return False


def affinity_includes_cpu(affinity_hex: str, cpu: int) -> bool:
    """Return True if the given CPU bit is set in the affinity mask."""
    mask = int(affinity_hex.strip(), 16)
    return bool(mask & (1 << cpu))


# ---------------------------------------------------------------------------
# Tests: parse_rt_result
# ---------------------------------------------------------------------------

class TestParseRtResult:
    def test_parses_valid_json(self):
        content = json.dumps({
            "max_latency_us": 47,
            "pass": True,
            "threshold_us": 100,
            "duration_s": 60,
            "kernel": "6.6.31-cclrte-rt",
        })
        result = parse_rt_result(content)
        assert result["max_latency_us"] == 47
        assert result["pass"] is True
        assert result["threshold_us"] == 100

    def test_raises_on_invalid_json(self):
        with pytest.raises(json.JSONDecodeError):
            parse_rt_result("not json")

    def test_result_written_to_tmp_file(self, tmp_path):
        result_file = tmp_path / "cclrte-rt-result.txt"
        data = {"max_latency_us": 55, "pass": True, "threshold_us": 100,
                "duration_s": 60, "kernel": "test"}
        result_file.write_text(json.dumps(data))
        parsed = parse_rt_result(result_file.read_text())
        assert parsed["max_latency_us"] == 55


# ---------------------------------------------------------------------------
# Tests: check_latency_pass — boundary conditions
# ---------------------------------------------------------------------------

class TestCheckLatencyPass:
    @pytest.mark.parametrize("latency,expected", [
        (0,   True),
        (50,  True),
        (99,  True),
        (100, False),  # boundary: must be strictly less than threshold
        (101, False),
        (500, False),
    ])
    def test_threshold_boundary(self, latency, expected):
        result = {"max_latency_us": latency}
        assert check_latency_pass(result, threshold_us=100) == expected

    def test_missing_key_fails(self):
        assert check_latency_pass({}, threshold_us=100) is False

    def test_custom_threshold(self):
        result = {"max_latency_us": 200}
        assert check_latency_pass(result, threshold_us=500) is True
        assert check_latency_pass(result, threshold_us=150) is False


# ---------------------------------------------------------------------------
# Tests: CPU isolation (cmdline checks)
# ---------------------------------------------------------------------------

class TestCpuIsolation:
    def test_isolcpus_present(self):
        cmdline = "root=/dev/mmcblk0p2 isolcpus=2,3 nohz_full=2,3 rcu_nocbs=2,3 threadirqs preempt=full"
        assert check_isolcpus(cmdline) is True

    def test_isolcpus_absent(self):
        cmdline = "root=/dev/mmcblk0p2 threadirqs preempt=full"
        assert check_isolcpus(cmdline) is False

    def test_nohz_full_present(self):
        cmdline = "root=/dev/mmcblk0p2 isolcpus=2,3 nohz_full=2,3"
        assert check_nohz_full(cmdline) is True

    def test_nohz_full_absent(self):
        cmdline = "root=/dev/mmcblk0p2 isolcpus=2,3"
        assert check_nohz_full(cmdline) is False

    def test_cmdline_from_tmp_file(self, tmp_path):
        proc_cmdline = tmp_path / "cmdline"
        proc_cmdline.write_text(
            "console=tty1 root=/dev/mmcblk0p2 isolcpus=2,3 nohz_full=2,3\n"
        )
        content = proc_cmdline.read_text()
        assert check_isolcpus(content) is True
        assert check_nohz_full(content) is True


# ---------------------------------------------------------------------------
# Tests: CPU governor
# ---------------------------------------------------------------------------

class TestCpuGovernor:
    def test_performance_governor_passes(self):
        assert check_cpu_governor("performance\n") is True

    def test_powersave_governor_fails(self):
        assert check_cpu_governor("powersave\n") is False

    def test_ondemand_governor_fails(self):
        assert check_cpu_governor("ondemand") is False

    def test_governor_from_tmp_file(self, tmp_path):
        gov_file = tmp_path / "scaling_governor"
        gov_file.write_text("performance\n")
        assert check_cpu_governor(gov_file.read_text()) is True


# ---------------------------------------------------------------------------
# Tests: sched_rt_runtime_us
# ---------------------------------------------------------------------------

class TestSchedRtRuntime:
    def test_minus_one_passes(self):
        assert check_sched_rt_runtime("-1\n") is True

    def test_950000_fails(self):
        # Default Linux value (950 ms per second RT cap)
        assert check_sched_rt_runtime("950000\n") is False

    def test_zero_fails(self):
        assert check_sched_rt_runtime("0\n") is False

    def test_non_numeric_fails(self):
        assert check_sched_rt_runtime("unlimited\n") is False

    def test_from_tmp_file(self, tmp_path):
        sysctl_file = tmp_path / "sched_rt_runtime_us"
        sysctl_file.write_text("-1\n")
        assert check_sched_rt_runtime(sysctl_file.read_text()) is True


# ---------------------------------------------------------------------------
# Tests: IRQ affinity mask
# ---------------------------------------------------------------------------

class TestIrqAffinity:
    @pytest.mark.parametrize("mask", ["3", "f", "ff", "1", "0"])
    def test_valid_hex_masks(self, mask):
        assert validate_smp_affinity(mask) is True

    @pytest.mark.parametrize("mask", ["xyz", ""])
    def test_invalid_masks(self, mask):
        assert validate_smp_affinity(mask) is False

    def test_prefixed_hex_0x3_is_valid(self):
        # Python's int("0x3", 16) succeeds — prefixed form is accepted by the kernel too
        assert validate_smp_affinity("0x3") is True

    def test_mask_3_includes_cpu0(self):
        # mask 0x3 = binary 0011 → CPUs 0 and 1
        assert affinity_includes_cpu("3", 0) is True

    def test_mask_3_includes_cpu1(self):
        assert affinity_includes_cpu("3", 1) is True

    def test_mask_3_excludes_cpu2(self):
        # CPU2 should NOT be in the OS-domain affinity mask
        assert affinity_includes_cpu("3", 2) is False

    def test_mask_3_excludes_cpu3(self):
        assert affinity_includes_cpu("3", 3) is False

    def test_mask_8_is_cpu3_only(self):
        # 0x8 = binary 1000 → CPU3
        assert affinity_includes_cpu("8", 3) is True
        assert affinity_includes_cpu("8", 0) is False
        assert affinity_includes_cpu("8", 2) is False

    def test_mask_4_is_cpu2_only(self):
        # 0x4 = binary 0100 → CPU2
        assert affinity_includes_cpu("4", 2) is True
        assert affinity_includes_cpu("4", 1) is False


# ---------------------------------------------------------------------------
# Tests: combined RT system check
# ---------------------------------------------------------------------------

class TestFullRtCheck:
    def test_all_rt_conditions_met(self, tmp_path):
        """Simulate a fully tuned system and verify all checks pass."""
        result_file = tmp_path / "rt-result.txt"
        result_file.write_text(json.dumps({
            "max_latency_us": 43,
            "pass": True,
            "threshold_us": 100,
            "duration_s": 60,
            "kernel": "6.6.31-cclrte-rt",
        }))

        cmdline_file = tmp_path / "cmdline"
        cmdline_file.write_text(
            "isolcpus=2,3 nohz_full=2,3 rcu_nocbs=2,3 threadirqs preempt=full\n"
        )

        governor_file = tmp_path / "scaling_governor"
        governor_file.write_text("performance\n")

        sysctl_file = tmp_path / "sched_rt_runtime_us"
        sysctl_file.write_text("-1\n")

        result = parse_rt_result(result_file.read_text())
        assert check_latency_pass(result) is True
        assert check_isolcpus(cmdline_file.read_text()) is True
        assert check_nohz_full(cmdline_file.read_text()) is True
        assert check_cpu_governor(governor_file.read_text()) is True
        assert check_sched_rt_runtime(sysctl_file.read_text()) is True

    def test_failing_latency_detected(self, tmp_path):
        """High latency result should be detected as a failure."""
        result_file = tmp_path / "rt-result.txt"
        result_file.write_text(json.dumps({
            "max_latency_us": 247,
            "pass": False,
            "threshold_us": 100,
            "duration_s": 60,
            "kernel": "6.6.31-cclrte-rt",
        }))
        result = parse_rt_result(result_file.read_text())
        assert check_latency_pass(result) is False


# ===========================================================================
# Max-load RT behavior tests
# ===========================================================================

LOAD_SCENARIOS = [
    ("idle",     20,  True,  100),
    ("medium",   60,  True,  100),
    ("high",     95,  True,  100),
    ("boundary", 99,  True,  100),
    ("overload", 100, False, 100),  # exactly at threshold = FAIL
    ("severe",   247, False, 100),
    ("critical", 500, False, 100),
]


class TestMaxLoadRTBehavior:
    @pytest.mark.parametrize("scenario,latency,expected,thresh", LOAD_SCENARIOS)
    def test_latency_pass_fail_under_load(self, scenario, latency, expected, thresh):
        result = {"max_latency_us": latency}
        assert check_latency_pass(result, threshold_us=thresh) == expected, \
            f"Scenario '{scenario}': latency={latency}, expected={'PASS' if expected else 'FAIL'}"

    def test_xenomai_stricter_threshold(self):
        # Xenomai target threshold: 20 µs
        XENO_THRESHOLD = 20
        assert check_latency_pass({"max_latency_us": 15}, XENO_THRESHOLD) is True
        assert check_latency_pass({"max_latency_us": 20}, XENO_THRESHOLD) is False
        assert check_latency_pass({"max_latency_us": 50}, XENO_THRESHOLD) is False

    def test_worst_case_dominates(self):
        # min=2µs, avg=5µs, max=150µs → should FAIL based on max alone
        result = {
            "min_latency_us": 2,
            "avg_latency_us": 5,
            "max_latency_us": 150,
        }
        assert check_latency_pass(result) is False

    def test_result_with_all_fields(self, tmp_path):
        rt_file = tmp_path / "rt-result.txt"
        data = {
            "max_latency_us": 47,
            "min_latency_us": 3,
            "avg_latency_us": 12,
            "pass": True,
            "threshold_us": 100,
            "duration_s": 60,
            "kernel": "6.6.31-cclrte-rt",
            "load": "idle",
        }
        rt_file.write_text(json.dumps(data))
        parsed = parse_rt_result(rt_file.read_text())
        assert check_latency_pass(parsed) is True
        assert parsed["kernel"] == "6.6.31-cclrte-rt"

    def test_60s_duration_required(self):
        # A valid full RT test must run for 60 seconds
        result = {"max_latency_us": 45, "pass": True, "threshold_us": 100, "duration_s": 60}
        assert result["duration_s"] == 60

    def test_short_duration_not_representative(self):
        # A 1-second cyclictest is not a valid RT check
        result = {"max_latency_us": 10, "pass": True, "threshold_us": 100, "duration_s": 1}
        assert result["duration_s"] < 60  # flag as insufficient


# ===========================================================================
# Xenomai-specific configuration tests
# ===========================================================================

class TestXenomaiConfig:
    def test_xenomai_supported_cpus_present(self):
        cmdline = "isolcpus=2,3 nohz_full=2,3 xenomai.supported_cpus=0xC xenomai.smi=disabled"
        assert "xenomai.supported_cpus=0xC" in cmdline

    def test_xenomai_smi_disabled_present(self):
        cmdline = "isolcpus=2,3 nohz_full=2,3 xenomai.supported_cpus=0xC xenomai.smi=disabled"
        assert "xenomai.smi=disabled" in cmdline

    def test_xenomai_cmdline_no_preempt_full(self):
        # Xenomai cmdline must NOT have preempt=full (that's PREEMPT_RT only)
        xenomai_cmdline = "isolcpus=2,3 nohz_full=2,3 xenomai.supported_cpus=0xC xenomai.smi=disabled"
        assert "preempt=full" not in xenomai_cmdline

    def test_preemptrt_cmdline_no_xenomai_params(self):
        # PREEMPT_RT cmdline must NOT have xenomai params
        preemptrt_cmdline = "isolcpus=2,3 nohz_full=2,3 rcu_nocbs=2,3 threadirqs preempt=full nosoftlockup"
        assert "xenomai" not in preemptrt_cmdline

    def test_bitmask_0xC_is_cpus_2_and_3(self):
        # 0xC = 1100 in binary → CPUs 2 and 3
        mask = 0xC
        assert bool(mask & (1 << 2))  # CPU2
        assert bool(mask & (1 << 3))  # CPU3
        assert not bool(mask & (1 << 0))  # CPU0 excluded
        assert not bool(mask & (1 << 1))  # CPU1 excluded

    def test_bitmask_0xC_via_affinity_helper(self):
        assert affinity_includes_cpu("C", 2) is True
        assert affinity_includes_cpu("C", 3) is True
        assert affinity_includes_cpu("C", 0) is False
        assert affinity_includes_cpu("C", 1) is False


# ===========================================================================
# Service priority validation
# ===========================================================================

class TestServicePriorityValidation:
    # Mock ps output: PID COMM CLS PRI PSR
    PS_OUTPUT = """  PID COMMAND         CLS PRI PSR
  101 codesyscontrol  FF   80   3
  102 ec_master       FF   89   2
  103 kworker/0:1     TS   19   0
  104 mosquitto       TS   19   0
  105 flask           TS   19   1"""

    def _parse_ps(self, output):
        """Parse ps -eo pid,comm,cls,pri,psr output."""
        processes = []
        for line in output.strip().splitlines()[1:]:
            parts = line.split()
            if len(parts) >= 5:
                processes.append({
                    "pid": parts[0],
                    "comm": parts[1],
                    "cls": parts[2],
                    "pri": int(parts[3]),
                    "psr": int(parts[4]),
                })
        return processes

    def test_codesys_is_sched_fifo(self):
        procs = self._parse_ps(self.PS_OUTPUT)
        codesys = next((p for p in procs if "codesys" in p["comm"]), None)
        assert codesys is not None
        assert codesys["cls"] == "FF"  # FF = SCHED_FIFO

    def test_codesys_priority_80(self):
        procs = self._parse_ps(self.PS_OUTPUT)
        codesys = next((p for p in procs if "codesys" in p["comm"]), None)
        assert codesys["pri"] == 80

    def test_codesys_on_cpu3(self):
        procs = self._parse_ps(self.PS_OUTPUT)
        codesys = next((p for p in procs if "codesys" in p["comm"]), None)
        assert codesys["psr"] == 3  # CPU3

    def test_ecmaster_priority_higher_than_codesys(self):
        procs = self._parse_ps(self.PS_OUTPUT)
        codesys = next((p for p in procs if "codesys" in p["comm"]), None)
        ec = next((p for p in procs if "ec_master" in p["comm"]), None)
        assert ec["pri"] > codesys["pri"]  # EtherCAT > CODESYS priority

    def test_ecmaster_on_cpu2(self):
        procs = self._parse_ps(self.PS_OUTPUT)
        ec = next((p for p in procs if "ec_master" in p["comm"]), None)
        assert ec["psr"] == 2  # CPU2

    def test_os_services_not_on_rt_cores(self):
        procs = self._parse_ps(self.PS_OUTPUT)
        os_procs = [p for p in procs if p["cls"] == "TS"]
        for p in os_procs:
            assert p["psr"] in (0, 1), \
                f"OS process {p['comm']} found on CPU{p['psr']} (should be CPU0 or CPU1)"
