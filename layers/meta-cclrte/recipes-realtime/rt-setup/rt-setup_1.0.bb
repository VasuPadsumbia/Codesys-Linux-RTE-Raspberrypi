DESCRIPTION = "Real-time system tuning for CODESYS motion control"
HOMEPAGE = "https://github.com/user/codesys-control-linux-rte"
LICENSE = "MIT"
LIC_FILES_CHKSUM = "file://${COMMON_LICENSE_DIR}/MIT;md5=0835ade698e0bcf8506ecda2f7b4f302"

inherit systemd

FILESEXTRAPATHS:prepend := "${THISDIR}/files:"

SRC_URI = " \
    file://rt-setup.sh \
    file://rt-setup.service \
    file://rt-sysctl.conf \
    file://cpu-motion.conf \
    file://cpufreq-setup.sh \
    file://xenomai-setup.sh \
    file://xenomai-setup.service \
"

SYSTEMD_SERVICE:${PN} = "rt-setup.service"
SYSTEMD_AUTO_ENABLE:${PN} = "enable"

do_install() {
    install -d ${D}${sbindir}
    install -m 0755 ${WORKDIR}/rt-setup.sh      ${D}${sbindir}/rt-setup.sh
    install -m 0755 ${WORKDIR}/cpufreq-setup.sh ${D}${sbindir}/cpufreq-setup.sh
    install -m 0755 ${WORKDIR}/xenomai-setup.sh ${D}${sbindir}/xenomai-setup.sh

    install -d ${D}${systemd_system_unitdir}
    install -m 0644 ${WORKDIR}/rt-setup.service     ${D}${systemd_system_unitdir}/rt-setup.service
    install -m 0644 ${WORKDIR}/xenomai-setup.service ${D}${systemd_system_unitdir}/xenomai-setup.service

    install -d ${D}${sysconfdir}/sysctl.d
    install -m 0644 ${WORKDIR}/rt-sysctl.conf \
        ${D}${sysconfdir}/sysctl.d/99-cclrte-rt.conf

    install -d ${D}${sysconfdir}/systemd/system.conf.d
    install -m 0644 ${WORKDIR}/cpu-motion.conf \
        ${D}${sysconfdir}/systemd/system.conf.d/99-cclrte-motion.conf

    install -d ${D}${localstatedir}/log
}

FILES:${PN} += " \
    ${sysconfdir}/sysctl.d/99-cclrte-rt.conf \
    ${sysconfdir}/systemd/system.conf.d/99-cclrte-motion.conf \
"

RDEPENDS:${PN} = "bash"
