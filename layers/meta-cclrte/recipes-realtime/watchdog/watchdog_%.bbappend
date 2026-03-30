# CCLRTE watchdog configuration overlay
FILESEXTRAPATHS:prepend := "${THISDIR}/files:"

SRC_URI:append = " file://watchdog.conf"

do_install:append() {
    install -m 0644 ${WORKDIR}/watchdog.conf ${D}${sysconfdir}/watchdog.conf
}
