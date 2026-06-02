FROM ubuntu:22.04

ARG DEBIAN_FRONTEND=noninteractive

# Yocto Scarthgap dependencies — Ubuntu 22.04
# https://docs.yoctoproject.org/ref-manual/system-requirements.html
RUN apt-get update && apt-get install -y --no-install-recommends \
    gawk wget git diffstat unzip texinfo gcc build-essential \
    chrpath socat cpio python3 python3-pip python3-pexpect xz-utils \
    debianutils iputils-ping python3-git python3-jinja2 python3-subunit \
    libegl1-mesa libsdl1.2-dev xterm mesa-common-dev zstd liblz4-tool \
    file locales lz4 libacl1 python3-distutils \
    util-linux pv ca-certificates curl sudo \
    && locale-gen en_US.UTF-8 \
    && rm -rf /var/lib/apt/lists/*

ENV LANG=en_US.UTF-8 \
    LANGUAGE=en_US:en \
    LC_ALL=en_US.UTF-8 \
    PYTHONUNBUFFERED=1

RUN pip3 install --no-cache-dir "kas>=4.0" flask

# Yocto refuses to run as root; builder user owns the cache dirs
RUN useradd -m -u 1000 -s /bin/bash builder \
    && echo "builder ALL=(ALL) NOPASSWD:ALL" >> /etc/sudoers \
    && mkdir -p /build-cache/downloads /build-cache/sstate-cache /build-cache/build \
    && chown -R builder:builder /build-cache

WORKDIR /workspace
USER builder
