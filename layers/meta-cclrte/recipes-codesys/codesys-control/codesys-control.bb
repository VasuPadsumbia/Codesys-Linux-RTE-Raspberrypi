# CODESYS Control for Linux SL — RT configuration and IDE auto-deploy support
#
# DEPLOYMENT FLOW (via CODESYS IDE):
#   1. Boot RPi5 with CCLRTE image (SSH + network configured)
#   2. Open CODESYS IDE on Windows/Linux
#   3. Tools > Update Raspberry Pi / Linux SL > SSH to device IP (192.168.2.100)
#   4. IDE transfers .deb via SFTP (requires Subsystem sftp in sshd_config)
#   5. IDE runs `dpkg -i *.deb` — intercepted by /usr/bin/dpkg shim which calls
#      install-codesys-runtime.sh (Python3-based .deb extraction, no dpkg needed)
#   6. codesys-ide-install.path fires -> codesys-post-install.sh
#      -> RT drop-in applied, service enabled, runtime started on CPU3 SCHED_FIFO 80
#
# ALTERNATIVE (manual, also works):
#   scp *.deb root@192.168.2.100:/tmp/
#   ssh root@192.168.2.100 /usr/sbin/install-codesys-runtime.sh /tmp/*.deb
#
# The CODESYS binary is CLOSED-LICENSE — not bundled in the image.
# See docs/INSTALLATION.md for CODESYS IDE setup instructions.

DESCRIPTION = "CODESYS Control for Linux SL — RT configuration and IDE auto-deploy"
HOMEPAGE = "https://store.codesys.com"
LICENSE = "CLOSED"

inherit systemd

FILESEXTRAPATHS:prepend := "${THISDIR}/files:"

SRC_URI = " \
    file://CODESYSControl.cfg \
    file://codesyscontrol.service \
    file://codesysgateway.service \
    file://rt-override.conf \
    file://codesys-ide-install.path \
    file://codesys-ide-install.service \
    file://codesys-setup.sh \
    file://codesys-post-install.sh \
    file://install-codesys-runtime.sh \
    file://dpkg-shim \
    file://apt-get-shim \
"

# Enable the path watcher — fires when IDE installs the runtime
# Gateway and runtime services are enabled by codesys-post-install.sh
SYSTEMD_SERVICE:${PN} = "codesys-ide-install.path codesysgateway.service codesyscontrol.service"
SYSTEMD_AUTO_ENABLE:${PN} = "enable"

do_install() {
    # ── Config ───────────────────────────────────────────────────────────────
    # /etc/codesyscontrol/ — path the .deb package creates and codesyscontrol.bin reads
    install -d ${D}${sysconfdir}/codesyscontrol
    install -m 0644 ${WORKDIR}/CODESYSControl.cfg   ${D}${sysconfdir}/codesyscontrol/CODESYSControl.cfg
    # /etc/codesys/ — used by our helper scripts (codesys-post-install.sh, codesys-setup.sh)
    install -d ${D}${sysconfdir}/codesys
    install -m 0644 ${WORKDIR}/CODESYSControl.cfg   ${D}${sysconfdir}/codesys/CODESYSControl.cfg
    install -m 0644 ${WORKDIR}/rt-override.conf     ${D}${sysconfdir}/codesys/rt-override.conf

    # ── systemd units ────────────────────────────────────────────────────────
    install -d ${D}${systemd_system_unitdir}
    install -m 0644 ${WORKDIR}/codesyscontrol.service \
        ${D}${systemd_system_unitdir}/codesyscontrol.service
    install -m 0644 ${WORKDIR}/codesysgateway.service \
        ${D}${systemd_system_unitdir}/codesysgateway.service
    install -m 0644 ${WORKDIR}/codesys-ide-install.path \
        ${D}${systemd_system_unitdir}/codesys-ide-install.path
    install -m 0644 ${WORKDIR}/codesys-ide-install.service \
        ${D}${systemd_system_unitdir}/codesys-ide-install.service

    # ── RT drop-in pre-installed (survives IDE reinstall) ───────────────────
    install -d ${D}${systemd_system_unitdir}/codesyscontrol.service.d
    install -m 0644 ${WORKDIR}/rt-override.conf \
        ${D}${systemd_system_unitdir}/codesyscontrol.service.d/rt-override.conf

    # ── Scripts ──────────────────────────────────────────────────────────────
    install -d ${D}${sbindir}
    install -m 0755 ${WORKDIR}/codesys-setup.sh              ${D}${sbindir}/codesys-setup.sh
    install -m 0755 ${WORKDIR}/codesys-post-install.sh       ${D}${sbindir}/codesys-post-install.sh
    install -m 0755 ${WORKDIR}/install-codesys-runtime.sh    ${D}${sbindir}/install-codesys-runtime.sh

    # ── dpkg / apt-get shims — CODESYS IDE compatibility ─────────────────────
    # The IDE runs `dpkg -i *.deb` and optionally `apt-get install -f` over SSH.
    # These shims intercept those calls so the IDE deploy wizard works on Yocto.
    install -d ${D}${bindir}
    install -m 0755 ${WORKDIR}/dpkg-shim      ${D}${bindir}/dpkg
    install -m 0755 ${WORKDIR}/apt-get-shim   ${D}${bindir}/apt-get

    # ── Pre-create runtime directories ───────────────────────────────────────
    install -d ${D}/opt/codesys/bin
    install -d ${D}/opt/codesys/lib
    install -d ${D}/opt/codesys/gateway
    install -d ${D}/var/opt/codesys/PlcLogic
    install -d ${D}/var/opt/codesys/cfg
    install -d ${D}/var/log/codesys

    # Shared library search path
    install -d ${D}${sysconfdir}/ld.so.conf.d
    echo "/opt/codesys/lib" > ${D}${sysconfdir}/ld.so.conf.d/codesys.conf
}

FILES:${PN} += " \
    ${sysconfdir}/codesyscontrol \
    ${sysconfdir}/codesys \
    ${sysconfdir}/ld.so.conf.d/codesys.conf \
    ${systemd_system_unitdir}/codesyscontrol.service.d \
    ${systemd_system_unitdir}/codesys-ide-install.service \
    /opt/codesys \
    /var/opt/codesys \
    /var/log/codesys \
"

# bash: setup/install scripts; libstdc++/libgcc: CODESYS runtime libs
# python3: used by install-codesys-runtime.sh to unpack .deb (no ar/dpkg needed)
RDEPENDS:${PN} = "bash libstdc++ libgcc python3"

# RuntimeDirectory=codesys in service files causes Yocto to pre-create
# /var/volatile/run/codesys — suppress the empty-dirs QA warning since
# systemd creates /run/codesys at service start time automatically.
INSANE_SKIP:${PN} += "empty-dirs"
