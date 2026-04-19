# CCLRTE watchdog configuration is provided via watchdog-config_%.bbappend
# The upstream watchdog recipe removes watchdog.conf from its own package
# (see poky/meta/recipes-extended/watchdog/watchdog_5.16.bb) and delegates
# it to the separate watchdog-config recipe. We override it there instead.
#
# Force watchdog.service to be enabled from first boot — independent of CODESYS.
# The upstream recipe does NOT auto-enable, so we override SYSTEMD_AUTO_ENABLE here.

inherit systemd
SYSTEMD_SERVICE:${PN} = "watchdog.service"
SYSTEMD_AUTO_ENABLE:${PN} = "enable"
