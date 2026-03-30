DESCRIPTION = "CCLRTE PLC WebUI — browser-based configuration interface"
HOMEPAGE = "https://github.com/user/codesys-control-linux-rte"
LICENSE = "MIT"
LIC_FILES_CHKSUM = "file://${COMMON_LICENSE_DIR}/MIT;md5=0835ade698e0bcf8506ecda2f7b4f302"

inherit systemd

FILESEXTRAPATHS:prepend := "${THISDIR}/files:"

SRC_URI = " \
    file://app.py \
    file://auth.py \
    file://plc-webui.service \
    file://templates/base.html \
    file://templates/login.html \
    file://templates/index.html \
    file://templates/network.html \
    file://templates/protocols.html \
    file://templates/codesys.html \
    file://templates/system.html \
    file://static/css/style.css \
    file://static/js/app.js \
"

SYSTEMD_SERVICE:${PN} = "plc-webui.service"
SYSTEMD_AUTO_ENABLE:${PN} = "enable"

do_install() {
    install -d ${D}/opt/cclrte/webui
    install -d ${D}/opt/cclrte/webui/templates
    install -d ${D}/opt/cclrte/webui/static/css
    install -d ${D}/opt/cclrte/webui/static/js

    install -m 0644 ${WORKDIR}/app.py     ${D}/opt/cclrte/webui/app.py
    install -m 0644 ${WORKDIR}/auth.py    ${D}/opt/cclrte/webui/auth.py

    install -m 0644 ${WORKDIR}/templates/base.html      ${D}/opt/cclrte/webui/templates/
    install -m 0644 ${WORKDIR}/templates/login.html     ${D}/opt/cclrte/webui/templates/
    install -m 0644 ${WORKDIR}/templates/index.html     ${D}/opt/cclrte/webui/templates/
    install -m 0644 ${WORKDIR}/templates/network.html   ${D}/opt/cclrte/webui/templates/
    install -m 0644 ${WORKDIR}/templates/protocols.html ${D}/opt/cclrte/webui/templates/
    install -m 0644 ${WORKDIR}/templates/codesys.html   ${D}/opt/cclrte/webui/templates/
    install -m 0644 ${WORKDIR}/templates/system.html    ${D}/opt/cclrte/webui/templates/

    install -m 0644 ${WORKDIR}/static/css/style.css ${D}/opt/cclrte/webui/static/css/
    install -m 0644 ${WORKDIR}/static/js/app.js     ${D}/opt/cclrte/webui/static/js/

    install -d ${D}${systemd_system_unitdir}
    install -m 0644 ${WORKDIR}/plc-webui.service ${D}${systemd_system_unitdir}/plc-webui.service
}

FILES:${PN} += "/opt/cclrte/webui"
RDEPENDS:${PN} = "python3 python3-flask python3-werkzeug python3-jinja2"
