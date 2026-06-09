DESCRIPTION = "CCLRTE extended I/O configuration — auto-detect HAT and configure ports"
LICENSE = "MIT"
LIC_FILES_CHKSUM = "file://${COMMON_LICENSE_DIR}/MIT;md5=0835ade698e0bcf8506ecda2f7b4f302"

FILESEXTRAPATHS:prepend := "${THISDIR}/files:"

SRC_URI = "file://extended-io-setup.sh"

do_install() {
    install -d ${D}${sbindir}
    install -m 0755 ${WORKDIR}/extended-io-setup.sh ${D}${sbindir}/extended-io-setup.sh
}

RDEPENDS:${PN} = "bash i2c-tools"
