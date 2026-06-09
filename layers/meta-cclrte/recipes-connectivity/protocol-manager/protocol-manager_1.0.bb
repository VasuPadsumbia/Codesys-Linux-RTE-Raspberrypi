DESCRIPTION = "CCLRTE protocol manager — mutual exclusivity for eth1 fieldbus protocols"
LICENSE = "MIT"
LIC_FILES_CHKSUM = "file://${COMMON_LICENSE_DIR}/MIT;md5=0835ade698e0bcf8506ecda2f7b4f302"

inherit systemd

FILESEXTRAPATHS:prepend := "${THISDIR}/files:"

SRC_URI = " \
    file://protocol-manager.sh \
    file://modbus-tcp.service \
    file://modbus-tcp-server.py \
"

do_install() {
    install -d ${D}${sbindir}
    install -m 0755 ${WORKDIR}/protocol-manager.sh  ${D}${sbindir}/protocol-manager.sh
    install -m 0755 ${WORKDIR}/modbus-tcp-server.py ${D}${sbindir}/modbus-tcp-server.py

    install -d ${D}${systemd_system_unitdir}
    install -m 0644 ${WORKDIR}/modbus-tcp.service \
        ${D}${systemd_system_unitdir}/modbus-tcp.service

    # State directory (active protocol tracking)
    install -d ${D}${localstatedir}/lib/cclrte
}

# modbus-tcp is not auto-enabled — protocol-manager.sh enables it on demand
SYSTEMD_SERVICE:${PN} = "modbus-tcp.service"
SYSTEMD_AUTO_ENABLE:${PN} = "disable"

FILES:${PN} += " \
    ${sbindir}/protocol-manager.sh \
    ${sbindir}/modbus-tcp-server.py \
    ${localstatedir}/lib/cclrte \
"

RDEPENDS:${PN} = "bash python3-core iproute2"
