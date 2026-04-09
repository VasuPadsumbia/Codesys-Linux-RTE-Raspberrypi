DESCRIPTION = "CODESYS Control Linux RTE — RPi5 2GB image (PREEMPT_RT)"
LICENSE = "MIT"

inherit core-image

IMAGE_FEATURES += "ssh-server-openssh package-management"

IMAGE_INSTALL:append = " \
    kernel-modules \
    linux-firmware-rpidistro-bcm43455 \
    linux-firmware-rpidistro-bcm43456 \
    rt-setup \
    rt-verify \
    watchdog \
    codesys-control \
    igh-ethercat \
    open62541 \
    mosquitto \
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
    openssh-sftp-server \
"

# Exclude packages pulled in as weak/recommended dependencies that are
# not needed on a headless industrial PLC.
BAD_RECOMMENDATIONS += " \
    avahi-daemon \
    avahi \
    rpcbind \
    ofono \
    connman \
"

IMAGE_ROOTFS_SIZE    = "524288"
IMAGE_OVERHEAD_FACTOR = "1.3"

inherit extrausers
# Default password: cclrte  (change via DEVICE_PASSWORD in /boot/site.conf on first boot)
# Generated with: openssl passwd -6 -salt 'cclrtesalt00' 'cclrte'
EXTRA_USERS_PARAMS = "usermod -p '\$6\$cclrtesalt00\$N9ucVAOkr0WGU0MFAb3xIxKk3nMErV9dyUKx1zLhS/nhOTDzG5S145q9cqq8EpX.OFvDIY3gXKEkpT4WcR.x10' root;"

ROOTFS_POSTPROCESS_COMMAND += "enable_root_ssh_password; setup_console_autologin;"

# Permit root password login in OpenSSH
enable_root_ssh_password () {
    sed -i 's/#PermitRootLogin.*/PermitRootLogin yes/' ${IMAGE_ROOTFS}/etc/ssh/sshd_config
    sed -i 's/PermitRootLogin prohibit-password/PermitRootLogin yes/' ${IMAGE_ROOTFS}/etc/ssh/sshd_config
}

# Auto-login root on serial console (ttyAMA0) and HDMI (tty1)
# Useful for lab access without SSH — password still required for SSH
setup_console_autologin () {
    for TTY in ttyAMA0 tty1; do
        SVC_DIR="${IMAGE_ROOTFS}/etc/systemd/system/serial-getty@${TTY}.service.d"
        if echo "${TTY}" | grep -q "^tty[0-9]"; then
            SVC_DIR="${IMAGE_ROOTFS}/etc/systemd/system/getty@${TTY}.service.d"
        fi
        install -d "${SVC_DIR}"
        cat > "${SVC_DIR}/autologin.conf" <<EOF
[Service]
ExecStart=
ExecStart=-/sbin/agetty --autologin root --noclear %I \$TERM
EOF
    done
}

# Enable serial console service (ttyAMA0 = primary UART after disable-bt overlay)
ROOTFS_POSTPROCESS_COMMAND += "enable_serial_console;"
enable_serial_console () {
    install -d ${IMAGE_ROOTFS}/etc/systemd/system/getty.target.wants
    ln -sf /lib/systemd/system/serial-getty@.service \
        ${IMAGE_ROOTFS}/etc/systemd/system/getty.target.wants/serial-getty@ttyAMA0.service
}
