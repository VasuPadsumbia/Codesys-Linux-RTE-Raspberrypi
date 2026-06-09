# Apply CCLRTE kernel configuration fragments to linux-raspberrypi
# Conditionally applies PREEMPT_RT or Xenomai Cobalt configs based on machine.

FILESEXTRAPATHS:prepend := "${THISDIR}/files:"

# ── PREEMPT_RT (rpi5-cclrte) ─────────────────────────────────────────────────
# 0001-arm64-select-ARCH_SUPPORTS_RT.patch: RPi kernel fork omits this mainline
#   arm64 Kconfig select — without it CONFIG_PREEMPT_RT has an unsatisfied
#   dependency and merge_config.sh silently falls back to CONFIG_PREEMPT=y.
# cclrte-rt.cfg           : PREEMPT_RT core, HZ=1000, NO_HZ_FULL
# cclrte-latency.cfg      : latency reduction (idle states, IRQ threading, cpufreq)
# cclrte-disable-debug.cfg: strip debug/trace overhead that adds jitter
SRC_URI:append:rpi5-cclrte = " \
    file://0001-arm64-select-ARCH_SUPPORTS_RT.patch \
    file://0002-sysfs-add-sys-kernel-realtime-entry.patch \
    file://cclrte-rt.cfg \
    file://cclrte-latency.cfg \
    file://cclrte-disable-debug.cfg \
"
LINUX_VERSION_EXTENSION:rpi5-cclrte = "-cclrte-rt"

# ── Xenomai Cobalt (rpi5-cclrte-xenomai) ─────────────────────────────────────
# xenomai-cobalt.cfg          : Dovetail IRQ pipeline, Cobalt co-kernel, HZ=1000
# xenomai-disable-features.cfg: strip PREEMPT_RT and debug features incompatible with Cobalt
# xenomai-bcm2712-extras.cfg  : BCM2712/RP1 specific options (RTC, PCIe, DVFS off)
#
# NOTE: Dovetail source patches are required for the Cobalt co-kernel to function.
# Obtain from https://source.denx.de/Xenomai/linux-dovetail (branch: v6.6.y/dovetail)
# Place in ${THISDIR}/files/patches/ and add to SRC_URI:append:rpi5-cclrte-xenomai below.
SRC_URI:append:rpi5-cclrte-xenomai = " \
    file://xenomai-cobalt.cfg \
    file://xenomai-disable-features.cfg \
    file://xenomai-bcm2712-extras.cfg \
"
# SRC_URI:append:rpi5-cclrte-xenomai = " \
#     file://patches/0001-dovetail-core-6.6.patch \
#     file://patches/0002-dovetail-arm64-6.6.patch \
# "
LINUX_VERSION_EXTENSION:rpi5-cclrte-xenomai = "-cclrte-xenomai"
