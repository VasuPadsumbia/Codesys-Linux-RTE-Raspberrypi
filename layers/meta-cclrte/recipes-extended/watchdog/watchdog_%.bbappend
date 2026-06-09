# CCLRTE: Enable watchdog.service at boot.
# The watchdog daemon must run to keep /dev/watchdog kicked every 2 s.
# Without this the service is installed but disabled, and the BCM2712
# hardware watchdog fires after 15 s causing an unexpected reboot.
#
# watchdog.service is owned by the watchdog package (not watchdog-config),
# so SYSTEMD_SERVICE must be set here, not in watchdog-config.bbappend.

inherit systemd
SYSTEMD_SERVICE:${PN} = "watchdog.service"
SYSTEMD_AUTO_ENABLE:${PN} = "enable"
