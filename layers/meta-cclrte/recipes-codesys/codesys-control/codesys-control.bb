# CODESYS Control for Linux SL — RT configuration and auto-install
# Author: Vasu Padsumbia
#
# DEPLOYMENT FLOW (automatic, first boot):
#   1. Boot RPi5 with CCLRTE image (network configured via site.conf)
#   2. codesys-firstboot.service runs once:
#        /usr/sbin/codesys-firstboot.sh
#        → installs .deb (binary) + .ipk (component libs) from /opt/codesys-packages/
#        → codesys-post-install.sh applies RT tuning (CPU3, SCHED_FIFO 80)
#        → creates stamp /var/lib/cclrte/codesys-installed
#   3. Connect CODESYS IDE to 192.168.2.100:1217 (no password — UserMgmtEnabled=0)
#
# REINSTALL (if needed):
#   rm /var/lib/cclrte/codesys-installed && systemctl start codesys-firstboot
#   OR: scp *.deb *.ipk root@192.168.2.100:/tmp/
#       /usr/sbin/install-codesys-runtime.sh /tmp/*.deb /tmp/*.ipk
#
# PACKAGES (must exist in data/ at repo root before building):
#   data/codesyscontrol_linuxarm64_4.20.0.0_arm64.deb  — runtime binary
#   data/codesyscontrol_linuxarm64_4.20.0.0_arm64.ipk  — component libraries
#
# KEY CONFIG DECISIONS (per debug session — see data/codesys plc.txt):
#   SchedulerInterval=500      must match task cycle (µs) — was 4000, caused 251 µs RT spikes
#   Logger.0.Enable=0          SD writes from CPU3 cause 200-400 µs latency spikes
#   [CmpUserMgmt] NOT [CmpUserMgr]  wrong section name silently blocks all IDE logins
#   FileReference.0=SysFileMap.cfg  required for CODESYS component file mapping
#   [SysTarget] version masks  required for IDE version compatibility

DESCRIPTION = "CODESYS Control for Linux SL — RT configuration and auto-install"
HOMEPAGE = "https://store.codesys.com"
LICENSE = "CLOSED"

inherit systemd

# Each files/ subdirectory is searched independently so SRC_URI uses flat filenames.
# The .deb/.ipk packages are NOT in SRC_URI — they live in data/ (gitignored) and are
# copied directly in do_install, bypassing the file:// fetcher which cannot resolve ../
FILESEXTRAPATHS:prepend := "${THISDIR}/files/config:${THISDIR}/files/services:${THISDIR}/files/scripts:${THISDIR}/files/shims:"

SRC_URI = " \
    file://CODESYSControl.cfg \
    file://CODESYSControl_User.cfg \
    file://codesyscontrol.service \
    file://codesysgateway.service \
    file://rt-override.conf \
    file://codesys-ide-install.path \
    file://codesys-ide-install.service \
    file://codesys-firstboot.service \
    file://codesys-firstboot.sh \
    file://codesys-setup.sh \
    file://codesys-post-install.sh \
    file://install-codesys-runtime.sh \
    file://dpkg-shim \
    file://apt-get-shim \
"

SYSTEMD_SERVICE:${PN} = " \
    codesys-firstboot.service \
    codesys-ide-install.path \
    codesyscontrol.service \
"
SYSTEMD_AUTO_ENABLE:${PN} = "enable"

do_install() {
    # ── Config — stored in /etc/codesys/ (our backup location) ──────────────
    # codesys-setup.sh copies these to /etc/codesyscontrol/ on first service start.
    # This two-location approach ensures our RT settings survive IDE reinstalls:
    # the IDE writes to /etc/codesyscontrol/CODESYSControl.cfg but never touches /etc/codesys/.
    install -d ${D}${sysconfdir}/codesys
    install -m 0644 ${WORKDIR}/CODESYSControl.cfg      ${D}${sysconfdir}/codesys/CODESYSControl.cfg
    install -m 0644 ${WORKDIR}/CODESYSControl_User.cfg ${D}${sysconfdir}/codesys/CODESYSControl_User.cfg
    install -m 0644 ${WORKDIR}/rt-override.conf        ${D}${sysconfdir}/codesys/rt-override.conf

    # ── systemd units ─────────────────────────────────────────────────────────
    install -d ${D}${systemd_system_unitdir}
    for svc in \
        codesyscontrol.service \
        codesysgateway.service \
        codesys-ide-install.path \
        codesys-ide-install.service \
        codesys-firstboot.service; do
        install -m 0644 ${WORKDIR}/$svc ${D}${systemd_system_unitdir}/$svc
    done

    # RT drop-in — pre-installed, survives IDE reinstalls
    install -d ${D}${systemd_system_unitdir}/codesyscontrol.service.d
    install -m 0644 ${WORKDIR}/rt-override.conf \
        ${D}${systemd_system_unitdir}/codesyscontrol.service.d/rt-override.conf

    # ── Scripts ───────────────────────────────────────────────────────────────
    install -d ${D}${sbindir}
    install -m 0755 ${WORKDIR}/codesys-setup.sh           ${D}${sbindir}/codesys-setup.sh
    install -m 0755 ${WORKDIR}/codesys-post-install.sh    ${D}${sbindir}/codesys-post-install.sh
    install -m 0755 ${WORKDIR}/codesys-firstboot.sh       ${D}${sbindir}/codesys-firstboot.sh
    install -m 0755 ${WORKDIR}/install-codesys-runtime.sh ${D}${sbindir}/install-codesys-runtime.sh

    # ── dpkg/apt shims — intercept IDE deploy calls on Yocto ─────────────────
    install -d ${D}${bindir}
    install -m 0755 ${WORKDIR}/dpkg-shim     ${D}${bindir}/dpkg
    install -m 0755 ${WORKDIR}/apt-get-shim  ${D}${bindir}/apt-get

    # ── Bundled CODESYS packages (installed on first boot) ────────────────────
    # Copied directly from data/ — not via SRC_URI/WORKDIR because the file://
    # fetcher cannot resolve ../ in FILESEXTRAPATHS on Yocto.
    # do_check_packages (runs before do_fetch) guarantees these exist.
    install -d ${D}/opt/codesys-packages
    install -m 0644 \
        ${TOPDIR}/../data/codesyscontrol_linuxarm64_4.20.0.0_arm64.deb \
        ${D}/opt/codesys-packages/
    install -m 0644 \
        ${TOPDIR}/../data/codesyscontrol_linuxarm64_4.20.0.0_arm64.ipk \
        ${D}/opt/codesys-packages/

    # ── Pre-create runtime directories ────────────────────────────────────────
    install -d ${D}/opt/codesys/bin
    install -d ${D}/opt/codesys/lib
    install -d ${D}/opt/codesys/gateway

    install -d ${D}/var/opt/codesys/PlcLogic
    install -d ${D}/var/opt/codesys/cfg
    # /var/log is volatile on Yocto — created at runtime by codesys-setup.sh

    # Shared library search path
    install -d ${D}${sysconfdir}/ld.so.conf.d
    echo "/opt/codesys/lib" > ${D}${sysconfdir}/ld.so.conf.d/codesys.conf
}

FILES:${PN} += " \
    ${sysconfdir}/codesys \
    ${sysconfdir}/ld.so.conf.d/codesys.conf \
    ${systemd_system_unitdir}/codesyscontrol.service.d \
    ${systemd_system_unitdir}/codesys-ide-install.service \
    ${systemd_system_unitdir}/codesysgateway.service \
    ${systemd_system_unitdir}/codesys-firstboot.service \
    ${bindir}/dpkg \
    ${bindir}/apt-get \
    /opt/codesys \
    /opt/codesys-packages \
    /var/opt/codesys \
"

# bash + python3: install scripts; libstdc++/libgcc: CODESYS runtime shared libs
RDEPENDS:${PN} = "bash libstdc++ libgcc python3-core"

# Verify that closed-license runtime packages exist in data/ before building.
# They are gitignored (binary blobs) — obtain from CODESYS IDE installer or store.codesys.com.
python do_check_packages() {
    import os, bb
    topdir = d.getVar('TOPDIR')
    data_dir = os.path.join(topdir, '..', 'data')
    deb = os.path.join(data_dir, 'codesyscontrol_linuxarm64_4.20.0.0_arm64.deb')
    ipk = os.path.join(data_dir, 'codesyscontrol_linuxarm64_4.20.0.0_arm64.ipk')
    missing = [f for f in [deb, ipk] if not os.path.isfile(f)]
    if missing:
        bb.fatal(
            "CODESYS runtime packages missing from data/:\n"
            + "\n".join(f"  {os.path.basename(m)}" for m in missing)
            + "\n\nObtain both files from CODESYS IDE (Help → Install CODESYS Control for Linux)"
            + "\nor from https://store.codesys.com and place in data/ at the repo root."
        )
}
addtask do_check_packages before do_fetch

# Suppress QA warnings for pre-created empty staging directories:
# /opt/codesys/bin, /opt/codesys/gateway — populated by codesys-firstboot at runtime
INSANE_SKIP:${PN} += "empty-dirs"
