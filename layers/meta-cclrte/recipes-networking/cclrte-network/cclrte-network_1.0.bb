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
    file://wpa_supplicant-runtime.conf \
    file://network-firstboot.sh \
    file://network-firstboot.service \
"

SYSTEMD_SERVICE:${PN} = "network-firstboot.service"
SYSTEMD_AUTO_ENABLE:${PN} = "enable"

do_install() {
    # systemd-networkd configuration
    install -d ${D}${sysconfdir}/systemd/network
    install -m 0644 ${WORKDIR}/10-eth0.network  ${D}${sysconfdir}/systemd/network/
    install -m 0644 ${WORKDIR}/20-wlan0.network ${D}${sysconfdir}/systemd/network/
    install -m 0644 ${WORKDIR}/25-eth1.network  ${D}${sysconfdir}/systemd/network/

    # WPA supplicant template (populated with site.conf credentials at first boot)
    install -d ${D}${sysconfdir}/wpa_supplicant
    install -m 0600 ${WORKDIR}/wpa_supplicant-wlan0.conf \
        ${D}${sysconfdir}/wpa_supplicant/wpa_supplicant-wlan0.conf

    # tmpfiles.d — create /run/wpa_supplicant socket dir at boot
    install -d ${D}${libdir}/tmpfiles.d
    install -m 0644 ${WORKDIR}/wpa_supplicant-runtime.conf \
        ${D}${libdir}/tmpfiles.d/wpa_supplicant-cclrte.conf

    # First-boot network setup script + service
    install -d ${D}${sbindir}
    install -m 0755 ${WORKDIR}/network-firstboot.sh ${D}${sbindir}/network-firstboot.sh
    install -d ${D}${systemd_system_unitdir}
    install -m 0644 ${WORKDIR}/network-firstboot.service \
        ${D}${systemd_system_unitdir}/network-firstboot.service

    # Enable required services via symlinks
    install -d ${D}${sysconfdir}/systemd/system/multi-user.target.wants
    ln -sf /lib/systemd/system/systemd-networkd.service \
        ${D}${sysconfdir}/systemd/system/multi-user.target.wants/systemd-networkd.service
    ln -sf /lib/systemd/system/systemd-resolved.service \
        ${D}${sysconfdir}/systemd/system/multi-user.target.wants/systemd-resolved.service
    ln -sf /lib/systemd/system/wpa_supplicant@.service \
        "${D}${sysconfdir}/systemd/system/multi-user.target.wants/wpa_supplicant@wlan0.service"

    # Point /etc/resolv.conf at systemd-resolved stub resolver
    install -d ${D}${sysconfdir}
    ln -sf /run/systemd/resolve/stub-resolv.conf ${D}${sysconfdir}/resolv.conf
}

FILES:${PN} += "${libdir}/tmpfiles.d"

RDEPENDS:${PN} = "bash wpa-supplicant rfkill systemd"
