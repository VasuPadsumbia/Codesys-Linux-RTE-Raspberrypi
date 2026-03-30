# Xenomai Cobalt patched kernel for RPi4
# Uses Dovetail interrupt pipeline (replaces old I-pipe in Xenomai 3.2+)
#
# PREREQUISITES:
#   1. Dovetail patches for RPi kernel 6.1 — obtain from:
#      https://source.denx.de/Xenomai/xenomai/-/wikis/Installing_Xenomai_3
#   2. Place patch files in ${THISDIR}/files/patches/
#   3. meta-xenomai layer at layers/meta-xenomai
#
# The Xenomai Cobalt co-kernel owns CPUs 2,3 (configured via cmdline).
# Linux runs as idle task of the Cobalt scheduler on CPUs 0,1.

DESCRIPTION = "Linux 6.1 for RPi4 with Xenomai Cobalt Dovetail hard-RT core"
LICENSE = "GPL-2.0-only"
LIC_FILES_CHKSUM = "file://COPYING;md5=6bc538ed5bd9a7fc9398086aedcd7e46"

inherit kernel
require recipes-kernel/linux/linux-raspberrypi.inc

LINUX_VERSION = "6.1"
LINUX_KERNEL_TYPE = "standard"
LINUX_VERSION_EXTENSION = "-cclrte-xenomai"

FILESEXTRAPATHS:prepend := "${THISDIR}/files:"

SRC_URI:append = " \
    file://xenomai-cobalt.cfg \
    file://xenomai-disable-features.cfg \
"

# Xenomai Dovetail patches must be placed in files/patches/ directory
# and listed here after download from Xenomai upstream.
# SRC_URI:append = " file://patches/0001-dovetail-arm64.patch"

COMPATIBLE_MACHINE = "rpi4-cclrte-xenomai"

# Xenomai userspace libraries are built separately by meta-xenomai layer
DEPENDS:append = " xenomai-native"
