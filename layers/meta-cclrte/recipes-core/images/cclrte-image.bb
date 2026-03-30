DESCRIPTION = "CODESYS Control Linux RTE — full RPi4 image (PREEMPT_RT)"
LICENSE = "MIT"

inherit core-image

IMAGE_FEATURES += "ssh-server-openssh package-management"

IMAGE_INSTALL:append = " \
    kernel-modules \
    linux-firmware \
    rt-setup \
    rt-verify \
    watchdog \
    codesys-control \
    igh-ethercat \
    open62541 \
    mosquitto \
    iolink-master \
    profinet-rt \
    cclrte-network \
    plc-webui \
    python3 \
    python3-flask \
    python3-werkzeug \
    python3-jinja2 \
    extended-io-config \
    rt-tests \
    i2c-tools \
    can-utils \
    ethtool \
    iproute2 \
    tcpdump \
    htop \
    nano \
    usbutils \
    stress-ng \
    openssh-sftp-server \
"

IMAGE_ROOTFS_SIZE    = "524288"
IMAGE_OVERHEAD_FACTOR = "1.3"
