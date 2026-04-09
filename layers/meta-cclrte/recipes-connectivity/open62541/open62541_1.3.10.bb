DESCRIPTION = "open62541 — open source OPC UA server/client library"
HOMEPAGE = "https://open62541.org"
LICENSE = "MPL-2.0"
LIC_FILES_CHKSUM = "file://LICENSE;md5=815ca599c9df247a0c7f619bab123dad"

inherit cmake

SRC_URI = "https://github.com/open62541/open62541/archive/refs/tags/v1.3.10.tar.gz"
SRC_URI[sha256sum] = "6bb51f55eeaf98fd5d9b61716bbae2ab9ac361fce0e62dfe23f8f2ecfb1de66f"

S = "${WORKDIR}/open62541-1.3.10"

DEPENDS = "mbedtls openssl python3-native"

EXTRA_OECMAKE = " \
    -DUA_ENABLE_AMALGAMATION=OFF \
    -DUA_BUILD_EXAMPLES=OFF \
    -DUA_BUILD_UNIT_TESTS=OFF \
    -DUA_ENABLE_ENCRYPTION=MBEDTLS \
    -DUA_ENABLE_SUBSCRIPTIONS=ON \
    -DUA_ENABLE_METHODCALLS=ON \
    -DUA_ENABLE_NODEMANAGEMENT=ON \
    -DUA_NAMESPACE_ZERO=REDUCED \
    -DBUILD_SHARED_LIBS=ON \
"

# Python codegen tools not needed on the PLC target — remove at install time
do_install:append() {
    rm -rf ${D}${datadir}/open62541
    rm -rf ${D}${datadir}
}

FILES:${PN}     = "${libdir}/lib*.so.*"
FILES:${PN}-dev = "${includedir} ${libdir}/lib*.so ${libdir}/pkgconfig ${libdir}/cmake"
