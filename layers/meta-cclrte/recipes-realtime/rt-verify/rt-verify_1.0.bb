DESCRIPTION = "RT latency verification using cyclictest — pass/fail gate for motion control"
HOMEPAGE = "https://github.com/user/codesys-control-linux-rte"
LICENSE = "MIT"
LIC_FILES_CHKSUM = "file://${COMMON_LICENSE_DIR}/MIT;md5=0835ade698e0bcf8506ecda2f7b4f302"

inherit systemd

FILESEXTRAPATHS:prepend := "${THISDIR}/files:"

SRC_URI = " \
    file://run-cyclictest.sh \
    file://rt-verify.service \
"

SYSTEMD_SERVICE:${PN} = "rt-verify.service"
SYSTEMD_AUTO_ENABLE:${PN} = "enable"

do_install() {
    install -d ${D}${sbindir}
    install -m 0755 ${WORKDIR}/run-cyclictest.sh ${D}${sbindir}/run-cyclictest.sh

    install -d ${D}${systemd_system_unitdir}
    install -m 0644 ${WORKDIR}/rt-verify.service ${D}${systemd_system_unitdir}/rt-verify.service
    # /var/log already exists on target — do not pre-create to avoid empty-dirs QA error
}

# rt-tests provides cyclictest binary
RDEPENDS:${PN} = "rt-tests bash python3 stress-ng"

# systemd bbclass may pre-create /var/volatile dirs; suppress spurious QA warning
INSANE_SKIP:${PN} += "empty-dirs"
