# CCLRTE: Ensure sshd listens on all interfaces (eth0 + wlan0)
FILESEXTRAPATHS:prepend := "${THISDIR}/files:"
SRC_URI:append = " file://sshd_config_cclrte"

do_install:append() {
    install -m 0600 ${WORKDIR}/sshd_config_cclrte ${D}${sysconfdir}/ssh/sshd_config
}
