DESCRIPTION = "open62541 — open source OPC UA server/client library"
HOMEPAGE = "https://open62541.org"
LICENSE = "MPL-2.0"
LIC_FILES_CHKSUM = "file://LICENSE;md5=815ca599c9df247a0c7f619bab123dad"

inherit cmake

SRC_URI = "https://github.com/open62541/open62541/archive/refs/tags/v1.3.10.tar.gz"
SRC_URI[sha256sum] = "REPLACE_WITH_ACTUAL_SHA256"
# sha256sum: wget https://github.com/open62541/open62541/archive/refs/tags/v1.3.10.tar.gz && sha256sum v1.3.10.tar.gz

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
    -DUA_NAMESPACE_ZERO=FULL \
    -DBUILD_SHARED_LIBS=ON \
"

FILES:${PN}     = "${libdir}/lib*.so.*"
FILES:${PN}-dev = "${includedir} ${libdir}/lib*.so ${libdir}/pkgconfig"
