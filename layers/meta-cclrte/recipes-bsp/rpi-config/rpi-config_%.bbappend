# Append real-time firmware settings to RPi config.txt
# These are applied on top of the standard meta-raspberrypi config

FILESEXTRAPATHS:prepend := "${THISDIR}/files:"

# All RT firmware settings are applied via RPI_EXTRA_CONFIG in rpi4-cclrte.conf.
# The fragment file is kept for reference and manual flashing scenarios.
SRC_URI:append = " file://config.txt.fragment"
