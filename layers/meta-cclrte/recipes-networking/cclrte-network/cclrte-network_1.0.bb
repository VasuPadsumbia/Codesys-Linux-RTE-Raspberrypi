DESCRIPTION = "CCLRTE network configuration — eth0 CODESYS port, wlan0 management"
LICENSE = "MIT"
LIC_FILES_CHKSUM = "file://${COMMON_LICENSE_DIR}/MIT;md5=0835ade698e0bcf8506ecda2f7b4f302"

inherit systemd

FILESEXTRAPATHS:prepend := "${THISDIR}/files:"

SRC_URI = " \
    file://10-eth0.network \
    file://20-wlan0.network \
    file://25-eth1.network \
    file://wpa_supplicant-wlan0.conf \
    file://network-firstboot.sh \
"

do_install() {
    # systemd-networkd configuration
    install -d ${D}${sysconfdir}/systemd/network
    install -m 0644 ${WORKDIR}/10-eth0.network  ${D}${sysconfdir}/systemd/network/
    install -m 0644 ${WORKDIR}/20-wlan0.network ${D}${sysconfdir}/systemd/network/
    install -m 0644 ${WORKDIR}/25-eth1.network  ${D}${sysconfdir}/systemd/network/

    # WPA supplicant template (populated with site.conf credentials at build time)
    install -d ${D}${sysconfdir}/wpa_supplicant
    install -m 0600 ${WORKDIR}/wpa_supplicant-wlan0.conf \
        ${D}${sysconfdir}/wpa_supplicant/wpa_supplicant-wlan0.conf

    # First-boot network setup script
    install -d ${D}${sbindir}
    install -m 0755 ${WORKDIR}/network-firstboot.sh ${D}${sbindir}/network-firstboot.sh

    # Enable required services
    install -d ${D}${sysconfdir}/systemd/system/multi-user.target.wants
    ln -sf /lib/systemd/system/systemd-networkd.service \
        ${D}${sysconfdir}/systemd/system/multi-user.target.wants/systemd-networkd.service
    ln -sf /lib/systemd/system/wpa_supplicant@.service \
        "${D}${sysconfdir}/systemd/system/multi-user.target.wants/wpa_supplicant@wlan0.service"
}

RDEPENDS:${PN} = "bash wpa-supplicant"
