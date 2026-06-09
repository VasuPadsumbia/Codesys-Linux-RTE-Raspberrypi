# p-net: PROFINET RT *device* (slave) stack by rt-labs
#
# NOTE: p-net implements the PROFINET IO Device (slave) role.
# For PROFINET IO Controller (master), use the CODESYS PROFINET SL add-on
# (available from CODESYS Store) or a Hilscher cifX card.
#
DESCRIPTION = "PROFINET RT device stack (p-net by rt-labs)"
HOMEPAGE = "https://github.com/rtlabs-com/p-net"
LICENSE = "BSD-3-Clause"
LIC_FILES_CHKSUM = "file://LICENSE;md5=3be7b8b182ccd96e48989b4e57311193"

inherit cmake

SRC_URI = " \
    git://github.com/rtlabs-com/p-net.git;protocol=https;branch=public;name=pnet \
    git://github.com/rtlabs-com/osal.git;protocol=https;branch=master;name=osal;destsuffix=git/osal \
    file://CMakeLists.txt \
    file://pnal_config.h \
    file://profinet.conf \
"
SRCREV_pnet = "459e043a44ffc97d25065434cc5b28c330142be9"
SRCREV_osal = "8e49f2440bb66bde748b34043716b5683890efe1"
SRCREV_FORMAT = "pnet_osal"

# The public branch ships source only — no CMakeLists.txt. Supply our own.
do_configure:prepend() {
    cp ${WORKDIR}/CMakeLists.txt ${S}/CMakeLists.txt
    cp ${WORKDIR}/pnal_config.h  ${S}/include/pnal_config.h
}
SRCREV = "459e043a44ffc97d25065434cc5b28c330142be9"
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
