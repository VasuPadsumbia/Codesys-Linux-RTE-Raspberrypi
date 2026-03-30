# Apply CCLRTE real-time kernel configuration fragments to linux-raspberrypi

FILESEXTRAPATHS:prepend := "${THISDIR}/files:"

# Three focused fragments:
#   cclrte-rt.cfg           : PREEMPT_RT core, HZ=1000, NO_HZ_FULL
#   cclrte-latency.cfg      : latency reduction (idle states, IRQ threading, cpufreq)
#   cclrte-disable-debug.cfg: strip debug/trace overhead that adds jitter
SRC_URI:append = " \
    file://cclrte-rt.cfg \
    file://cclrte-latency.cfg \
    file://cclrte-disable-debug.cfg \
"

# Append a suffix so RT-patched modules stay separate in sstate cache
LINUX_VERSION_EXTENSION:append = "-cclrte-rt"
