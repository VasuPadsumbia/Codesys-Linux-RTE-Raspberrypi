# p-net: PROFINET RT *device* (slave) stack by rt-labs
#
# NOTE: p-net implements the PROFINET IO Device (slave) role.
# For PROFINET IO Controller (master), use the CODESYS PROFINET SL add-on
# (available from CODESYS Store) or a Hilscher cifX card.
#
DESCRIPTION = "PROFINET RT device stack (p-net by rt-labs)"
HOMEPAGE = "https://github.com/rtlabs-com/p-net"
LICENSE = "BSD-3-Clause"
LIC_FILES_CHKSUM = "file://LICENSE;md5=REPLACE_WITH_ACTUAL_MD5"

inherit cmake

SRC_URI = " \
    git://github.com/rtlabs-com/p-net.git;protocol=https;branch=main \
    file://profinet.conf \
"
SRCREV = "${AUTOREV}"
PV = "1.0+git${SRCPV}"

S = "${WORKDIR}/git"
DEPENDS = "linux-libc-headers"

EXTRA_OECMAKE = " \
    -DBUILD_TESTING=OFF \
    -DBUILD_SHARED_LIBS=ON \
"

do_install:append() {
    install -d ${D}${sysconfdir}/profinet
    install -m 0644 ${WORKDIR}/profinet.conf ${D}${sysconfdir}/profinet/profinet.conf
}

FILES:${PN} += "${sysconfdir}/profinet"
