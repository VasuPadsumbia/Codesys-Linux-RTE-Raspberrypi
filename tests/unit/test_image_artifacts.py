"""
Unit tests for build image artifact verification.

Validates:
  - KAS YAML configuration files are syntactically correct and complete
  - meta-cclrte layer structure is intact
  - Image recipes contain expected packages
  - Kernel config fragments have the correct RT settings
  - Build artifacts exist when a build has been run (skipped otherwise)
"""
import os

import pytest
import yaml

# Repository root relative to this test file
REPO_ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), "../.."))
KAS_DIR = os.path.join(REPO_ROOT, "kas")
LAYER_DIR = os.path.join(REPO_ROOT, "layers/meta-cclrte")
BUILD_DIR = os.path.join(REPO_ROOT, "build")


def read_file(path):
    with open(path) as f:
        return f.read()


def load_yaml(path):
    with open(path) as f:
        return yaml.safe_load(f)


# ---------------------------------------------------------------------------
# KAS configuration file tests
# ---------------------------------------------------------------------------

class TestKasConfigs:
    def test_base_yml_is_valid_yaml(self):
        data = load_yaml(os.path.join(KAS_DIR, "base.yml"))
        assert data is not None

    def test_base_yml_has_header_version(self):
        data = load_yaml(os.path.join(KAS_DIR, "base.yml"))
        assert data["header"]["version"] == 14

    def test_base_yml_has_repos(self):
        data = load_yaml(os.path.join(KAS_DIR, "base.yml"))
        assert "repos" in data
        assert "poky" in data["repos"]
        assert "meta-openembedded" in data["repos"]
        assert "meta-cclrte" in data["repos"]

    def test_base_yml_has_local_conf_header(self):
        data = load_yaml(os.path.join(KAS_DIR, "base.yml"))
        assert "local_conf_header" in data

    def test_base_yml_poky_has_url_and_refspec(self):
        data = load_yaml(os.path.join(KAS_DIR, "base.yml"))
        poky = data["repos"]["poky"]
        assert "url" in poky
        assert "refspec" in poky
        assert poky["refspec"] == "scarthgap"

    def test_base_yml_meta_oe_has_required_layers(self):
        data = load_yaml(os.path.join(KAS_DIR, "base.yml"))
        oe = data["repos"]["meta-openembedded"]
        layers = oe.get("layers", {})
        assert "meta-oe" in layers
        assert "meta-networking" in layers
        assert "meta-python" in layers

    def test_rpi4_64_is_valid_yaml(self):
        data = load_yaml(os.path.join(KAS_DIR, "rpi4-64.yml"))
        assert data is not None

    def test_rpi4_64_machine(self):
        data = load_yaml(os.path.join(KAS_DIR, "rpi4-64.yml"))
        assert data["machine"] == "rpi4-cclrte"

    def test_rpi4_64_target(self):
        data = load_yaml(os.path.join(KAS_DIR, "rpi4-64.yml"))
        assert data["target"] == "cclrte-image"

    def test_rpi4_64_includes_base(self):
        data = load_yaml(os.path.join(KAS_DIR, "rpi4-64.yml"))
        # kas >=5.x: includes is under header
        includes = data.get("header", {}).get("includes", data.get("includes", []))
        assert any("base" in str(i) for i in includes)

    def test_rpi4_64_has_version_14(self):
        data = load_yaml(os.path.join(KAS_DIR, "rpi4-64.yml"))
        assert data["header"]["version"] == 14

    def test_rpi4_64_has_meta_raspberrypi(self):
        data = load_yaml(os.path.join(KAS_DIR, "rpi4-64.yml"))
        assert "meta-raspberrypi" in data.get("repos", {})

    def test_rpi4_64_has_meta_realtime(self):
        data = load_yaml(os.path.join(KAS_DIR, "rpi4-64.yml"))
        assert "meta-realtime" in data.get("repos", {})

    def test_rpi4_xenomai_is_valid_yaml(self):
        data = load_yaml(os.path.join(KAS_DIR, "rpi4-xenomai.yml"))
        assert data is not None

    def test_rpi4_xenomai_machine(self):
        data = load_yaml(os.path.join(KAS_DIR, "rpi4-xenomai.yml"))
        assert data["machine"] == "rpi4-cclrte-xenomai"

    def test_rpi4_xenomai_target(self):
        data = load_yaml(os.path.join(KAS_DIR, "rpi4-xenomai.yml"))
        assert data["target"] == "cclrte-xenomai-image"

    def test_rpi4_xenomai_has_meta_xenomai(self):
        data = load_yaml(os.path.join(KAS_DIR, "rpi4-xenomai.yml"))
        repos = data.get("repos", {})
        assert "meta-xenomai" in repos

    def test_rpi4_xenomai_meta_xenomai_is_local_path(self):
        data = load_yaml(os.path.join(KAS_DIR, "rpi4-xenomai.yml"))
        xeno = data["repos"]["meta-xenomai"]
        # Local layers use 'path', not 'url'
        assert "path" in xeno
        assert "url" not in xeno

    def test_qemu_is_valid_yaml(self):
        data = load_yaml(os.path.join(KAS_DIR, "qemu-x86-64.yml"))
        assert data is not None

    def test_qemu_machine(self):
        data = load_yaml(os.path.join(KAS_DIR, "qemu-x86-64.yml"))
        assert data["machine"] == "qemux86-64"

    def test_qemu_target(self):
        data = load_yaml(os.path.join(KAS_DIR, "qemu-x86-64.yml"))
        assert data["target"] == "cclrte-image-qemu"

    def test_qemu_has_version_14(self):
        data = load_yaml(os.path.join(KAS_DIR, "qemu-x86-64.yml"))
        assert data["header"]["version"] == 14

    def test_all_kas_files_have_version_14(self):
        for fname in ["base.yml", "rpi4-64.yml", "rpi4-xenomai.yml", "qemu-x86-64.yml"]:
            data = load_yaml(os.path.join(KAS_DIR, fname))
            assert data["header"]["version"] == 14, f"{fname}: expected header.version=14"

    def test_scarthgap_refspec_consistency(self):
        """All remote repos must use scarthgap."""
        for fname in ["rpi4-64.yml", "rpi4-xenomai.yml"]:
            data = load_yaml(os.path.join(KAS_DIR, fname))
            for name, repo in data.get("repos", {}).items():
                if "url" in repo:  # remote repos only
                    assert repo["refspec"] == "scarthgap", \
                        f"{fname}/{name}: expected refspec=scarthgap, got {repo['refspec']}"


# ---------------------------------------------------------------------------
# Layer structure tests
# ---------------------------------------------------------------------------

class TestLayerConf:
    def test_layer_conf_exists(self):
        path = os.path.join(LAYER_DIR, "conf/layer.conf")
        assert os.path.exists(path), f"Missing: {path}"

    def test_distro_conf_exists(self):
        path = os.path.join(LAYER_DIR, "conf/distro/cclrte.conf")
        assert os.path.exists(path), f"Missing: {path}"

    def test_machine_rpi4_conf_exists(self):
        path = os.path.join(LAYER_DIR, "conf/machine/rpi4-cclrte.conf")
        assert os.path.exists(path), f"Missing: {path}"

    def test_machine_xenomai_conf_exists(self):
        path = os.path.join(LAYER_DIR, "conf/machine/rpi4-cclrte-xenomai.conf")
        assert os.path.exists(path), f"Missing: {path}"

    def test_layer_conf_has_bbfiles(self):
        content = read_file(os.path.join(LAYER_DIR, "conf/layer.conf"))
        assert "BBFILES" in content

    def test_layer_conf_has_priority(self):
        content = read_file(os.path.join(LAYER_DIR, "conf/layer.conf"))
        assert "BBFILE_PRIORITY" in content

    def test_layer_conf_scarthgap_compat(self):
        content = read_file(os.path.join(LAYER_DIR, "conf/layer.conf"))
        assert "scarthgap" in content

    def test_distro_conf_sets_distro_name(self):
        content = read_file(os.path.join(LAYER_DIR, "conf/distro/cclrte.conf"))
        assert '"cclrte"' in content and "DISTRO" in content

    def test_machine_rpi4_inherits_raspberrypi(self):
        content = read_file(os.path.join(LAYER_DIR, "conf/machine/rpi4-cclrte.conf"))
        assert "raspberrypi4" in content.lower()

    def test_machine_rpi4_cmdline_has_isolcpus(self):
        content = read_file(os.path.join(LAYER_DIR, "conf/machine/rpi4-cclrte.conf"))
        assert "isolcpus=2,3" in content

    def test_machine_rpi4_cmdline_has_nohz_full(self):
        content = read_file(os.path.join(LAYER_DIR, "conf/machine/rpi4-cclrte.conf"))
        assert "nohz_full=2,3" in content

    def test_machine_xenomai_requires_rpi4(self):
        content = read_file(os.path.join(LAYER_DIR, "conf/machine/rpi4-cclrte-xenomai.conf"))
        assert "rpi4-cclrte.conf" in content

    def test_machine_xenomai_sets_xenomai_kernel(self):
        content = read_file(os.path.join(LAYER_DIR, "conf/machine/rpi4-cclrte-xenomai.conf"))
        assert "linux-raspberrypi-xenomai" in content

    def test_machine_xenomai_has_xenomai_cmdline(self):
        content = read_file(os.path.join(LAYER_DIR, "conf/machine/rpi4-cclrte-xenomai.conf"))
        assert "xenomai.supported_cpus" in content


# ---------------------------------------------------------------------------
# Image recipe tests
# ---------------------------------------------------------------------------

class TestImageRecipes:
    IMAGE_DIR = os.path.join(LAYER_DIR, "recipes-core/images")

    def test_cclrte_image_exists(self):
        assert os.path.exists(os.path.join(self.IMAGE_DIR, "cclrte-image.bb"))

    def test_cclrte_image_qemu_exists(self):
        assert os.path.exists(os.path.join(self.IMAGE_DIR, "cclrte-image-qemu.bb"))

    def test_cclrte_xenomai_image_exists(self):
        assert os.path.exists(os.path.join(self.IMAGE_DIR, "cclrte-xenomai-image.bb"))

    @pytest.mark.parametrize("pkg", [
        "codesys-control",
        "igh-ethercat",
        "plc-webui",
        "rt-setup",
        "rt-verify",
        "mosquitto",
        "open62541",
        "profinet-rt",
        "iolink-master",
        "cclrte-network",
        "watchdog",
        "rt-tests",
        "stress-ng",
    ])
    def test_cclrte_image_contains_package(self, pkg):
        content = read_file(os.path.join(self.IMAGE_DIR, "cclrte-image.bb"))
        assert pkg in content, f"Package '{pkg}' not found in cclrte-image.bb"

    def test_cclrte_image_has_ssh_server(self):
        content = read_file(os.path.join(self.IMAGE_DIR, "cclrte-image.bb"))
        assert "ssh-server" in content

    def test_cclrte_xenomai_image_references_xenomai(self):
        content = read_file(os.path.join(self.IMAGE_DIR, "cclrte-xenomai-image.bb"))
        assert "xenomai" in content.lower()

    def test_cclrte_xenomai_image_includes_base(self):
        content = read_file(os.path.join(self.IMAGE_DIR, "cclrte-xenomai-image.bb"))
        # Should require or include the base image
        assert "cclrte-image" in content or "require" in content

    def test_cclrte_image_rootfs_size_set(self):
        content = read_file(os.path.join(self.IMAGE_DIR, "cclrte-image.bb"))
        assert "IMAGE_ROOTFS_SIZE" in content

    def test_cclrte_image_overhead_factor_set(self):
        content = read_file(os.path.join(self.IMAGE_DIR, "cclrte-image.bb"))
        assert "IMAGE_OVERHEAD_FACTOR" in content

    def test_qemu_image_no_rpi_bsp_packages(self):
        content = read_file(os.path.join(self.IMAGE_DIR, "cclrte-image-qemu.bb"))
        # QEMU image should not include RPi-specific BSP packages
        rpi_packages = ["linux-firmware-rpidistro", "rpi-config", "userland"]
        for pkg in rpi_packages:
            assert pkg not in content, f"RPi BSP package '{pkg}' found in QEMU image"


# ---------------------------------------------------------------------------
# Kernel config fragment tests
# ---------------------------------------------------------------------------

class TestKernelConfigs:
    KERNEL_CFG_DIR = os.path.join(LAYER_DIR, "recipes-kernel/linux/files")
    XENOMAI_CFG_DIR = os.path.join(LAYER_DIR, "recipes-kernel/linux-xenomai/files")

    def test_cclrte_rt_cfg_exists(self):
        assert os.path.exists(os.path.join(self.KERNEL_CFG_DIR, "cclrte-rt.cfg"))

    def test_cclrte_latency_cfg_exists(self):
        assert os.path.exists(os.path.join(self.KERNEL_CFG_DIR, "cclrte-latency.cfg"))

    def test_cclrte_disable_debug_cfg_exists(self):
        assert os.path.exists(os.path.join(self.KERNEL_CFG_DIR, "cclrte-disable-debug.cfg"))

    def test_rt_cfg_has_preempt_rt(self):
        content = read_file(os.path.join(self.KERNEL_CFG_DIR, "cclrte-rt.cfg"))
        assert "CONFIG_PREEMPT_RT=y" in content

    def test_rt_cfg_has_hz_1000(self):
        content = read_file(os.path.join(self.KERNEL_CFG_DIR, "cclrte-rt.cfg"))
        assert "CONFIG_HZ=1000" in content

    def test_rt_cfg_has_hz_1000_kconfig(self):
        content = read_file(os.path.join(self.KERNEL_CFG_DIR, "cclrte-rt.cfg"))
        assert "CONFIG_HZ_1000=y" in content

    def test_rt_cfg_has_no_hz_full(self):
        content = read_file(os.path.join(self.KERNEL_CFG_DIR, "cclrte-rt.cfg"))
        assert "CONFIG_NO_HZ_FULL=y" in content

    def test_rt_cfg_has_rcu_nocb(self):
        content = read_file(os.path.join(self.KERNEL_CFG_DIR, "cclrte-rt.cfg"))
        assert "CONFIG_RCU_NOCB_CPU=y" in content

    def test_rt_cfg_disables_transparent_hugepage(self):
        content = read_file(os.path.join(self.KERNEL_CFG_DIR, "cclrte-rt.cfg"))
        assert "CONFIG_TRANSPARENT_HUGEPAGE=n" in content

    def test_latency_cfg_disables_cpu_idle(self):
        content = read_file(os.path.join(self.KERNEL_CFG_DIR, "cclrte-latency.cfg"))
        assert "CONFIG_CPU_IDLE=n" in content

    def test_debug_cfg_disables_ftrace(self):
        content = read_file(os.path.join(self.KERNEL_CFG_DIR, "cclrte-disable-debug.cfg"))
        assert "CONFIG_FTRACE=n" in content

    def test_debug_cfg_disables_sched_debug(self):
        content = read_file(os.path.join(self.KERNEL_CFG_DIR, "cclrte-disable-debug.cfg"))
        assert "CONFIG_SCHED_DEBUG=n" in content

    def test_xenomai_cfg_exists(self):
        assert os.path.exists(os.path.join(self.XENOMAI_CFG_DIR, "xenomai-cobalt.cfg"))

    def test_xenomai_cfg_has_dovetail(self):
        content = read_file(os.path.join(self.XENOMAI_CFG_DIR, "xenomai-cobalt.cfg"))
        assert "CONFIG_DOVETAIL=y" in content

    def test_xenomai_cfg_has_irq_pipeline(self):
        content = read_file(os.path.join(self.XENOMAI_CFG_DIR, "xenomai-cobalt.cfg"))
        assert "CONFIG_IRQ_PIPELINE=y" in content

    def test_xenomai_disable_cfg_disables_preempt_rt(self):
        content = read_file(os.path.join(self.XENOMAI_CFG_DIR, "xenomai-disable-features.cfg"))
        assert "CONFIG_PREEMPT_RT=n" in content

    def test_xenomai_disable_cfg_disables_cpu_idle(self):
        content = read_file(os.path.join(self.XENOMAI_CFG_DIR, "xenomai-disable-features.cfg"))
        assert "CONFIG_CPU_IDLE=n" in content


# ---------------------------------------------------------------------------
# Build artifact tests (skipped if build directory doesn't exist)
# ---------------------------------------------------------------------------

PREEMPT_RT_IMAGE_DIR = os.path.join(BUILD_DIR, "tmp/deploy/images/rpi4-cclrte")
XENOMAI_IMAGE_DIR = os.path.join(BUILD_DIR, "tmp/deploy/images/rpi4-cclrte-xenomai")
QEMU_IMAGE_DIR = os.path.join(BUILD_DIR, "tmp/deploy/images/qemux86-64")


class TestBuildArtifacts:
    @pytest.mark.skipif(
        not os.path.isdir(PREEMPT_RT_IMAGE_DIR),
        reason="PREEMPT_RT build not found — run './cclrte.sh build preempt-rt' first",
    )
    def test_preemptrt_sdimg_exists(self):
        images = [f for f in os.listdir(PREEMPT_RT_IMAGE_DIR) if f.endswith(".rpi-sdimg")]
        assert len(images) >= 1, f"No .rpi-sdimg found in {PREEMPT_RT_IMAGE_DIR}"

    @pytest.mark.skipif(
        not os.path.isdir(PREEMPT_RT_IMAGE_DIR),
        reason="PREEMPT_RT build not found",
    )
    def test_preemptrt_image_is_named_correctly(self):
        images = [f for f in os.listdir(PREEMPT_RT_IMAGE_DIR) if f.endswith(".rpi-sdimg")]
        assert any("cclrte-image" in img for img in images), \
            f"Expected 'cclrte-image' in filename, got: {images}"

    @pytest.mark.skipif(
        not os.path.isdir(XENOMAI_IMAGE_DIR),
        reason="Xenomai build not found — run './cclrte.sh build xenomai' first",
    )
    def test_xenomai_sdimg_exists(self):
        images = [f for f in os.listdir(XENOMAI_IMAGE_DIR) if f.endswith(".rpi-sdimg")]
        assert len(images) >= 1, f"No .rpi-sdimg found in {XENOMAI_IMAGE_DIR}"

    @pytest.mark.skipif(
        not os.path.isdir(XENOMAI_IMAGE_DIR),
        reason="Xenomai build not found",
    )
    def test_xenomai_image_is_named_correctly(self):
        images = [f for f in os.listdir(XENOMAI_IMAGE_DIR) if f.endswith(".rpi-sdimg")]
        assert any("xenomai" in img for img in images), \
            f"Expected 'xenomai' in filename, got: {images}"

    @pytest.mark.skipif(
        not os.path.isdir(QEMU_IMAGE_DIR),
        reason="QEMU build not found — run './cclrte.sh build qemu' first",
    )
    def test_qemu_image_exists(self):
        all_files = os.listdir(QEMU_IMAGE_DIR)
        image_files = [
            f for f in all_files
            if f.endswith((".wic", ".wic.bz2", ".ext4", ".hddimg"))
        ]
        assert len(image_files) >= 1, f"No QEMU image found in {QEMU_IMAGE_DIR}"

    @pytest.mark.skipif(
        not os.path.isdir(QEMU_IMAGE_DIR),
        reason="QEMU build not found",
    )
    def test_qemu_image_is_named_correctly(self):
        all_files = os.listdir(QEMU_IMAGE_DIR)
        image_files = [f for f in all_files if "cclrte-image-qemu" in f]
        assert len(image_files) >= 1, f"No 'cclrte-image-qemu' file in {QEMU_IMAGE_DIR}"

    @pytest.mark.skipif(
        not os.path.isdir(QEMU_IMAGE_DIR),
        reason="QEMU build not found",
    )
    def test_qemu_image_not_empty(self):
        all_files = os.listdir(QEMU_IMAGE_DIR)
        image_files = [
            f for f in all_files
            if "cclrte-image-qemu" in f and not f.endswith(".manifest")
        ]
        if image_files:
            img_path = os.path.join(QEMU_IMAGE_DIR, image_files[0])
            size = os.path.getsize(img_path)
            assert size > 1024 * 1024, f"Image too small: {size} bytes (expected > 1MB)"
