DESCRIPTION = "IgH EtherCAT Master for Linux — kernel module and userspace tools"
HOMEPAGE = "https://gitlab.com/etherlab.org/ethercat"
LICENSE = "GPL-2.0-only & LGPL-2.1-only"
LIC_FILES_CHKSUM = " \
    file://COPYING;md5=59530bdf33659b29e73d4adb9f9f6552 \
    file://COPYING.LESSER;md5=4fbd65380cdd255951079008b364516c \
"

inherit module autotools pkgconfig systemd

SRC_URI = " \
    https://gitlab.com/etherlab.org/ethercat/-/archive/1.5.2/ethercat-1.5.2.tar.gz \
    file://ethercat.conf \
    file://ethercat.service \
"
SRC_URI[sha256sum] = "c266f143b01ea6c618b54d85068e90662c25c56a7888fad1e0eafccf03388ceb"

S = "${WORKDIR}/ethercat-1.5.2"

DEPENDS = "virtual/kernel"

# automake requires ChangeLog — not included in the GitLab archive tarball.
# AM_INIT_AUTOMAKE has -Werror; add subdir-objects to silence the related warning.
do_configure:prepend() {
    touch ${S}/ChangeLog
    sed -i 's/AM_INIT_AUTOMAKE(\[-Wall -Werror/AM_INIT_AUTOMAKE([-Wall -Werror subdir-objects/' ${S}/configure.ac
}

# lib/ioctl.h includes master/ioctl.h relative to source root — add it to include path
CFLAGS:append = " -I${S}"

EXTRA_OECONF = " \
    --with-linux-dir=${STAGING_KERNEL_BUILDDIR} \
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

FILES:${PN} += " \
    ${sysconfdir}/ethercat.conf \
    ${sysconfdir}/sysconfig/ethercat \
    ${sbindir}/ethercatctl \
    ${bindir}/ethercat \
    ${libdir}/libethercat.so.* \
"
FILES:${PN}-dev += "${libdir}/libethercat.so"
RDEPENDS:${PN} = "bash"
