# CODESYS Control for Linux SL — RT configuration and IDE auto-deploy support
#
# DEPLOYMENT FLOW:
#   1. Boot RPi5 with CCLRTE image (SSH + network configured)
#   2. Open CODESYS IDE on Windows/Linux
#   3. Tools > Update Raspberry Pi / Linux SL > SSH to device IP
#   4. IDE installs runtime + gateway to /opt/codesys/ via SSH
#   5. codesys-ide-install.path fires -> codesys-post-install.sh
#      -> RT drop-in applied, service enabled, runtime started on CPU3 SCHED_FIFO 80
#
# The CODESYS binary is CLOSED-LICENSE — not bundled in the image.
# See docs/INSTALLATION.md for CODESYS IDE setup instructions.

DESCRIPTION = "CODESYS Control for Linux SL — RT configuration and IDE auto-deploy"
HOMEPAGE = "https://store.codesys.com"
LICENSE = "CLOSED"

inherit systemd

FILESEXTRAPATHS:prepend := "${THISDIR}/files:"

SRC_URI = " \
    file://CODESYSControl.cfg \
    file://codesyscontrol.service \
    file://codesysgateway.service \
    file://rt-override.conf \
    file://codesys-ide-install.path \
    file://codesys-ide-install.service \
    file://codesys-setup.sh \
    file://codesys-post-install.sh \
    file://install-codesys-runtime.sh \
"

# Enable the path watcher — fires when IDE installs the runtime
# Gateway and runtime services are enabled by codesys-post-install.sh
SYSTEMD_SERVICE:${PN} = "codesys-ide-install.path codesysgateway.service codesyscontrol.service"
SYSTEMD_AUTO_ENABLE:${PN} = "enable"

do_install() {
    # ── Config ───────────────────────────────────────────────────────────────
    install -d ${D}${sysconfdir}/codesys
    install -m 0644 ${WORKDIR}/CODESYSControl.cfg   ${D}${sysconfdir}/codesys/CODESYSControl.cfg
    install -m 0644 ${WORKDIR}/rt-override.conf     ${D}${sysconfdir}/codesys/rt-override.conf
    # Also place at /etc/CODESYSControl.cfg — standard CODESYS lookup path
    install -m 0644 ${WORKDIR}/CODESYSControl.cfg   ${D}${sysconfdir}/CODESYSControl.cfg

    # ── systemd units ────────────────────────────────────────────────────────
    install -d ${D}${systemd_system_unitdir}
    install -m 0644 ${WORKDIR}/codesyscontrol.service \
        ${D}${systemd_system_unitdir}/codesyscontrol.service
    install -m 0644 ${WORKDIR}/codesysgateway.service \
        ${D}${systemd_system_unitdir}/codesysgateway.service
    install -m 0644 ${WORKDIR}/codesys-ide-install.path \
        ${D}${systemd_system_unitdir}/codesys-ide-install.path
    install -m 0644 ${WORKDIR}/codesys-ide-install.service \
        ${D}${systemd_system_unitdir}/codesys-ide-install.service

    # ── RT drop-in pre-installed (survives IDE reinstall) ───────────────────
    install -d ${D}${systemd_system_unitdir}/codesyscontrol.service.d
    install -m 0644 ${WORKDIR}/rt-override.conf \
        ${D}${systemd_system_unitdir}/codesyscontrol.service.d/rt-override.conf

    # ── Scripts ──────────────────────────────────────────────────────────────
    install -d ${D}${sbindir}
    install -m 0755 ${WORKDIR}/codesys-setup.sh              ${D}${sbindir}/codesys-setup.sh
    install -m 0755 ${WORKDIR}/codesys-post-install.sh       ${D}${sbindir}/codesys-post-install.sh
    install -m 0755 ${WORKDIR}/install-codesys-runtime.sh    ${D}${sbindir}/install-codesys-runtime.sh

    # ── Pre-create runtime directories ───────────────────────────────────────
    install -d ${D}/opt/codesys/bin
    install -d ${D}/opt/codesys/lib
    install -d ${D}/opt/codesys/gateway
    install -d ${D}/var/opt/codesys/PlcLogic
    install -d ${D}/var/opt/codesys/cfg
    install -d ${D}/var/log/codesys

    # Shared library search path
    install -d ${D}${sysconfdir}/ld.so.conf.d
    echo "/opt/codesys/lib" > ${D}${sysconfdir}/ld.so.conf.d/codesys.conf
}

FILES:${PN} += " \
    ${sysconfdir}/codesys \
    ${sysconfdir}/CODESYSControl.cfg \
    ${sysconfdir}/ld.so.conf.d/codesys.conf \
    ${systemd_system_unitdir}/codesyscontrol.service.d \
    ${systemd_system_unitdir}/codesys-ide-install.service \
    /opt/codesys \
    /var/opt/codesys \
    /var/log/codesys \
"

# bash: setup/install scripts; libstdc++/libgcc: CODESYS runtime libs
# binutils: provides ar(1) needed by install-codesys-runtime.sh to unpack .deb
RDEPENDS:${PN} = "bash libstdc++ libgcc binutils"

# RuntimeDirectory=codesys in service files causes Yocto to pre-create
# /var/volatile/run/codesys — suppress the empty-dirs QA warning since
# systemd creates /run/codesys at service start time automatically.
INSANE_SKIP:${PN} += "empty-dirs"
