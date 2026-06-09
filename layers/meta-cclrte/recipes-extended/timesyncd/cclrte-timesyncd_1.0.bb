# Configure chrony for CCLRTE PLC time synchronization.
# Installs:
#   /etc/chrony/conf.d/10-cclrte.conf   — Cloudflare + Google NTP servers
#   chronyd.service.d/network.conf      — wait for network-online.target
#   systemd-networkd-wait-online.service.d/any.conf — --any so eth0 static
#                                         is enough to fire network-online
#   network-online.target.wants symlink — enables systemd-networkd-wait-online
#
# Accurate system time is required for:
#   - OPC-UA timestamps to match SCADA / engineering PC
#   - CODESYS log timestamps to correlate with IDE and historian
#   - RT latency report timestamps
#
# The RPi5 hardware RTC (PCF85063A) is synced from NTP via rtcsync
# and maintains time across power cycles even without network.

DESCRIPTION = "CCLRTE NTP configuration via chrony"
LICENSE = "MIT"
LIC_FILES_CHKSUM = "file://${COMMON_LICENSE_DIR}/MIT;md5=0835ade698e0bcf8506ecda2f7b4f302"

inherit systemd

SRC_URI = "file://chrony.conf \
           file://chronyd-network.conf \
           file://wait-online-any.conf \
          "

do_install() {
    # NTP server list — loaded via chrony confdir
    install -d ${D}${sysconfdir}/chrony/conf.d
    install -m 0644 ${WORKDIR}/chrony.conf ${D}${sysconfdir}/chrony/conf.d/10-cclrte.conf

    # Make chronyd wait until at least one interface is online
    install -d ${D}${systemd_system_unitdir}/chronyd.service.d
    install -m 0644 ${WORKDIR}/chronyd-network.conf \
        ${D}${systemd_system_unitdir}/chronyd.service.d/network.conf

    # Override systemd-networkd-wait-online to use --any --timeout=60
    install -d ${D}${systemd_system_unitdir}/systemd-networkd-wait-online.service.d
    install -m 0644 ${WORKDIR}/wait-online-any.conf \
        ${D}${systemd_system_unitdir}/systemd-networkd-wait-online.service.d/any.conf

    # Enable systemd-networkd-wait-online via symlink (WantedBy=network-online.target)
    install -d ${D}${sysconfdir}/systemd/system/network-online.target.wants
    ln -sf ${systemd_system_unitdir}/systemd-networkd-wait-online.service \
        ${D}${sysconfdir}/systemd/system/network-online.target.wants/systemd-networkd-wait-online.service
}

FILES:${PN} = " \
    ${sysconfdir}/chrony/conf.d/10-cclrte.conf \
    ${systemd_system_unitdir}/chronyd.service.d/network.conf \
    ${systemd_system_unitdir}/systemd-networkd-wait-online.service.d/any.conf \
    ${sysconfdir}/systemd/system/network-online.target.wants/systemd-networkd-wait-online.service \
"

RDEPENDS:${PN} = "chrony"
