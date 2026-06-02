DESCRIPTION = "IO-Link Master stack for Linux (rt-labs i-link)"
HOMEPAGE = "https://github.com/rtlabs-com/i-link"
LICENSE = "BSD-3-Clause"
LIC_FILES_CHKSUM = "file://LICENSE;md5=3be7b8b182ccd96e48989b4e57311193"

inherit cmake

SRC_URI = " \
    git://github.com/rtlabs-com/i-link.git;protocol=https;branch=public;name=ilink \
    git://github.com/rtlabs-com/osal.git;protocol=https;branch=master;name=osal;destsuffix=git/osal \
    file://CMakeLists.txt \
    file://iolink.conf \
"
SRCREV_ilink = "9f5fe0f7c6a45fa96a8d2439dcbe60bb2415793d"
SRCREV_osal  = "8e49f2440bb66bde748b34043716b5683890efe1"
SRCREV_FORMAT = "ilink_osal"

# The public branch ships source only — no CMakeLists.txt. Supply our own.
do_configure:prepend() {
    cp ${WORKDIR}/CMakeLists.txt ${S}/CMakeLists.txt
}
SRCREV = "9f5fe0f7c6a45fa96a8d2439dcbe60bb2415793d"
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
