DESCRIPTION = "CODESYS Control Linux RTE — minimal QEMU image for CI testing"
LICENSE = "MIT"

inherit core-image

IMAGE_FEATURES += "ssh-server-openssh"

# No RPi-specific packages, no hardware protocol stacks
IMAGE_INSTALL:append = " \
    kernel-modules \
    rt-setup \
    rt-verify \
    cclrte-network \
    plc-webui \
    python3 \
    python3-flask \
    python3-werkzeug \
    python3-jinja2 \
    rt-tests \
    stress-ng \
    openssh-sftp-server \
"
