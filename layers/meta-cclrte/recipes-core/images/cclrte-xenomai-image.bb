DESCRIPTION = "CODESYS Control Linux RTE — Xenomai Cobalt hard RT image"
LICENSE = "MIT"

# Inherit everything from the PREEMPT_RT image; add Xenomai Cobalt userspace
require cclrte-image.bb

IMAGE_INSTALL:append = " \
    xenomai-libcobalt \
    xenomai-utils \
"
