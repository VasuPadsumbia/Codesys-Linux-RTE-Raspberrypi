DESCRIPTION = "CODESYS Control Linux RTE — RPi5 Xenomai Cobalt hard RT image"
LICENSE = "MIT"

# Inherit everything from the PREEMPT_RT image
# xenomai-libcobalt / xenomai-utils come from meta-xenomai — add back once
# a scarthgap-compatible meta-xenomai layer is available.
require cclrte-image.bb
