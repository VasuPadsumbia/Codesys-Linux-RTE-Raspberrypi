DESCRIPTION = "Active cooler fan control — maintains RPi5 CPU at 50-60°C"
LICENSE = "MIT"
LIC_FILES_CHKSUM = "file://${COMMON_LICENSE_DIR}/MIT;md5=0835ade698e0bcf8506ecda2f7b4f302"

inherit systemd

FILESEXTRAPATHS:prepend := "${THISDIR}/files:"

SRC_URI = " \
    file://fan-control.sh \
    file://fan-control.service \
"

SYSTEMD_SERVICE:${PN} = "fan-control.service"
SYSTEMD_AUTO_ENABLE:${PN} = "enable"

do_install() {
    install -d ${D}${sbindir}
    install -m 0755 ${WORKDIR}/fan-control.sh ${D}${sbindir}/fan-control.sh

    install -d ${D}${systemd_system_unitdir}
    install -m 0644 ${WORKDIR}/fan-control.service \
        ${D}${systemd_system_unitdir}/fan-control.service
}

RDEPENDS:${PN} = "bash"
