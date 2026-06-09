# CCLRTE: Override the default watchdog configuration with our BCM2712/RPi5
# tuned version and deploy the watchdog repair helper script.
#
# The upstream watchdog-config.bb (poky/meta/recipes-extended/watchdog/
# watchdog-config.bb) installs /etc/watchdog.conf from its own files/ dir.
# By prepending our layer's files/ directory we shadow the upstream file so
# that our version is used during do_install without touching the watchdog
# package itself (which deliberately does NOT own watchdog.conf).
#
# This is the CORRECT place to customise /etc/watchdog.conf.  Do NOT install
# watchdog.conf from watchdog_%.bbappend — doing so causes opkg to report a
# file-clash because watchdog-config already owns that path.

FILESEXTRAPATHS:prepend := "${THISDIR}/files:"

# Pull in the repair script alongside the config file
SRC_URI:append = " file://cclrte-watchdog-repair.sh"

do_install:append() {
    install -d ${D}${sbindir}
    install -m 0755 ${WORKDIR}/cclrte-watchdog-repair.sh \
        ${D}${sbindir}/cclrte-watchdog-repair.sh
}

# Declare that watchdog-config owns the repair script binary
FILES:${PN} += "${sbindir}/cclrte-watchdog-repair.sh"

# bash is required by the repair script
RDEPENDS:${PN} += "bash"
