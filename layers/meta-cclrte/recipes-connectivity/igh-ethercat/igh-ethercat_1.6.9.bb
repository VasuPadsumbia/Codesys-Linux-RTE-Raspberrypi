DESCRIPTION = "IgH EtherCAT Master for Linux — kernel module and userspace tools"
HOMEPAGE = "https://gitlab.com/etherlab.org/ethercat"
LICENSE = "GPL-2.0-only & LGPL-2.1-only"
LIC_FILES_CHKSUM = " \
    file://COPYING;md5=59530bdf33659b29e73d4adb9f9f6552 \
    file://COPYING.LESSER;md5=4fbd65380cdd255951079008b364516c \
"

inherit module autotools pkgconfig systemd

SRC_URI = " \
    https://gitlab.com/etherlab.org/ethercat/-/archive/1.6.9/ethercat-1.6.9.tar.gz \
    file://ethercat.conf \
    file://ethercat.service \
"
SRC_URI[sha256sum] = "2bc4d6b69ed980b896ecae9ea6603b327562dfacd3b8c1ed4e9e599a4cc4dfc3"

S = "${WORKDIR}/ethercat-1.6.9"

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
    --disable-cycles \
    --disable-eoe \
"

# IgH native r8169 driver does not support kernel 6.6 — use generic driver.
# ec_generic sends EtherCAT frames via AF_PACKET over the kernel r8169 NIC.

FILESEXTRAPATHS:prepend := "${THISDIR}/files:"

# IgH is an out-of-source autotools build:
#   ${S}/<subdir>/ — source .c/.h files
#   ${B}/<subdir>/ — generated Kbuild + Makefile (no .c files)
#
# The kernel's 'make M=<dir> modules' sets $(src)=<dir> and looks for .c files
# there — so it can't find them in ${B}. Fix: symlink .c/.h from ${S} into ${B}
# before invoking the kernel build. master built first — devices/Kbuild
# KBUILD_EXTRA_SYMBOLS needs master/Module.symvers.
do_compile:append() {
    rm -f  "${B}/globals.h" && ln -sf "${S}/globals.h" "${B}/globals.h"
    rm -rf "${B}/include"   && ln -sf "${S}/include"   "${B}/include"

    for src_dir in "${S}/master" "${S}/devices"; do
        build_dir="${B}/$(basename ${src_dir})"
        find "${src_dir}" -maxdepth 1 \( -name "*.c" -o -name "*.h" \) | \
            xargs -I{} ln -sf {} "${build_dir}/"
    done

    oe_runmake -C "${STAGING_KERNEL_BUILDDIR}" M="${B}/master" modules
    # devices/Kbuild KBUILD_EXTRA_SYMBOLS has two entries:
    #   ${B}/Module.symvers        (top-level — empty in a split build)
    #   ${B}/master/Module.symvers (ec_master symbols)
    # Copying master/Module.symvers to ${B}/Module.symvers causes "exported twice".
    # Touch an empty file so the path exists but adds no duplicate symbols.
    touch "${B}/Module.symvers"
    oe_runmake -C "${STAGING_KERNEL_BUILDDIR}" M="${B}/devices" LINUX_SYMVERS=Module.symvers modules
}

# 1.6.9: include/Makefile has no install target — autotools_do_install (which runs
# 'make install') fails. Use install-exec to install binaries + libs only;
# headers are not needed in the rootfs.
# Also: IgH's modules_install does not forward INSTALL_MOD_PATH — install directly.
do_install() {
    # ${B}/include was symlinked to ${S}/include in do_compile for kernel module headers.
    # ${S}/include/Makefile has no install-exec target; replace symlink with stub so
    # top-level 'make install-exec' can recurse safely without errors.
    if [ -L "${B}/include" ]; then
        rm -f "${B}/include"
        mkdir -p "${B}/include"
        printf 'all install install-exec install-data:\n\t@:\n' > "${B}/include/Makefile"
    fi

    oe_runmake DESTDIR="${D}" install-exec

    install -d ${D}${sysconfdir}
    install -m 0644 ${WORKDIR}/ethercat.conf ${D}${sysconfdir}/ethercat.conf

    install -d ${D}${systemd_system_unitdir}
    install -m 0644 ${WORKDIR}/ethercat.service \
        ${D}${systemd_system_unitdir}/ethercat.service

    oe_runmake -C "${STAGING_KERNEL_BUILDDIR}" \
        M="${B}/master" DEPMOD=echo \
        MODLIB="${D}${nonarch_base_libdir}/modules/${KERNEL_VERSION}" \
        INSTALL_MOD_STRIP=1 modules_install
    oe_runmake -C "${STAGING_KERNEL_BUILDDIR}" \
        M="${B}/devices" DEPMOD=echo \
        MODLIB="${D}${nonarch_base_libdir}/modules/${KERNEL_VERSION}" \
        INSTALL_MOD_STRIP=1 modules_install
    find ${D}${nonarch_base_libdir}/modules \( -name "build" -o -name "source" \) -exec rm -rf {} + 2>/dev/null || true
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
RDEPENDS:${PN} += "kernel-module-ec-master kernel-module-ec-generic"

KERNEL_MODULE_AUTOLOAD += "ec_master"
