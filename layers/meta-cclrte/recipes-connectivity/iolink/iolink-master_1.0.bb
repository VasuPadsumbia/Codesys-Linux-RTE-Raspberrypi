DESCRIPTION = "IO-Link Master stack for Linux (rt-labs iol)"
HOMEPAGE = "https://github.com/rtlabs-com/iol"
LICENSE = "BSD-3-Clause"
LIC_FILES_CHKSUM = "file://LICENSE;md5=REPLACE_WITH_ACTUAL_MD5"

inherit cmake

SRC_URI = " \
    git://github.com/rtlabs-com/iol.git;protocol=https;branch=main \
    file://iolink.conf \
"
SRCREV = "${AUTOREV}"
PV = "1.0+git${SRCPV}"

S = "${WORKDIR}/git"

DEPENDS = "linux-libc-headers"

EXTRA_OECMAKE = " \
    -DBUILD_SHARED_LIBS=ON \
    -DBUILD_TESTING=OFF \
    -DIOLINK_BUILD_SAMPLE=OFF \
"

do_install:append() {
    install -d ${D}${sysconfdir}/iolink
    install -m 0644 ${WORKDIR}/iolink.conf ${D}${sysconfdir}/iolink/iolink.conf
}

FILES:${PN} += "${sysconfdir}/iolink"
