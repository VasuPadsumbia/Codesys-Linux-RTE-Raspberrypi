# CODESYS Control for Linux SL — configuration, service, and runtime installer
#
# The CODESYS binary is a CLOSED-LICENSE commercial product.
# This recipe installs the configuration, systemd service, and a helper script.
# The runtime binary must be obtained separately from the CODESYS Store and
# installed on the target using: /usr/sbin/install-codesys-runtime.sh
#
# See docs/INSTALLATION.md for step-by-step instructions.

DESCRIPTION = "CODESYS Control for Linux SL — PLC runtime configuration and installer"
HOMEPAGE = "https://store.codesys.com"
LICENSE = "CLOSED"

inherit systemd

FILESEXTRAPATHS:prepend := "${THISDIR}/files:"

SRC_URI = " \
    file://CODESYSControl.cfg \
    file://codesyscontrol.service \
    file://codesys-setup.sh \
    file://install-codesys-runtime.sh \
"

SYSTEMD_SERVICE:${PN} = "codesyscontrol.service"
SYSTEMD_AUTO_ENABLE:${PN} = "enable"

do_install() {
    # Configuration
    install -d ${D}${sysconfdir}
    install -m 0644 ${WORKDIR}/CODESYSControl.cfg ${D}${sysconfdir}/CODESYSControl.cfg

    # systemd unit
    install -d ${D}${systemd_system_unitdir}
    install -m 0644 ${WORKDIR}/codesyscontrol.service \
        ${D}${systemd_system_unitdir}/codesyscontrol.service

    # Helper scripts
    install -d ${D}${sbindir}
    install -m 0755 ${WORKDIR}/codesys-setup.sh        ${D}${sbindir}/codesys-setup.sh
    install -m 0755 ${WORKDIR}/install-codesys-runtime.sh \
        ${D}${sbindir}/install-codesys-runtime.sh

    # Runtime directories (binary installed separately via install-codesys-runtime.sh)
    install -d ${D}/opt/codesys/bin
    install -d ${D}/opt/codesys/lib
    install -d ${D}/var/opt/codesys/PlcLogic
    install -d ${D}/var/opt/codesys/cfg
    install -d ${D}/var/log/codesys
    install -d ${D}/run/codesys

    # Shared library search path
    install -d ${D}${sysconfdir}/ld.so.conf.d
    echo "/opt/codesys/lib" > ${D}${sysconfdir}/ld.so.conf.d/codesys.conf
}

FILES:${PN} += " \
    /opt/codesys \
    /var/opt/codesys \
    /var/log/codesys \
    ${sysconfdir}/ld.so.conf.d/codesys.conf \
"

RDEPENDS:${PN} = "bash libstdc++ libgcc"
