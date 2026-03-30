DESCRIPTION = "IgH EtherCAT Master for Linux — kernel module and userspace tools"
HOMEPAGE = "https://gitlab.com/etherlab.org/ethercat"
LICENSE = "GPL-2.0-only & LGPL-2.1-only"
LIC_FILES_CHKSUM = " \
    file://COPYING;md5=b234ee4d69f5fce4486a80fdaf4a4263 \
    file://COPYING.LESSER;md5=4fbd65380cdd255951079008b364516c \
"

inherit module autotools pkgconfig systemd

SRC_URI = " \
    https://gitlab.com/etherlab.org/ethercat/-/archive/1.5.2/ethercat-1.5.2.tar.gz \
    file://ethercat.conf \
    file://ethercat.service \
"
SRC_URI[sha256sum] = "33f20e33d970f9a37b19b0d6b7d1a9a0b1e9e5e9cf2d9a8e3b3e5e3e3e3e3e3e"
# NOTE: Replace the sha256sum above with the actual checksum after downloading:
#   wget https://gitlab.com/etherlab.org/ethercat/-/archive/1.5.2/ethercat-1.5.2.tar.gz
#   sha256sum ethercat-1.5.2.tar.gz

S = "${WORKDIR}/ethercat-1.5.2"

DEPENDS = "virtual/kernel"

EXTRA_OECONF = " \
    --with-linux-dir=${STAGING_KERNEL_DIR} \
    --enable-generic \
    --disable-8139too \
    --disable-e100 \
    --disable-e1000 \
    --disable-e1000e \
    --enable-hrtimer \
    --enable-cycles \
"

FILESEXTRAPATHS:prepend := "${THISDIR}/files:"

do_install:append() {
    install -d ${D}${sysconfdir}
    install -m 0644 ${WORKDIR}/ethercat.conf ${D}${sysconfdir}/ethercat.conf

    install -d ${D}${systemd_system_unitdir}
    install -m 0644 ${WORKDIR}/ethercat.service \
        ${D}${systemd_system_unitdir}/ethercat.service
}

SYSTEMD_SERVICE:${PN} = "ethercat.service"
SYSTEMD_AUTO_ENABLE:${PN} = "enable"

FILES:${PN} += "${sysconfdir}/ethercat.conf"
RDEPENDS:${PN} = "bash"
