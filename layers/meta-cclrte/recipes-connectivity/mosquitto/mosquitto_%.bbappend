# CCLRTE: Enable WebSocket support in Mosquitto for WebUI connectivity
PACKAGECONFIG:append = " websockets"

# Auto-enable mosquitto.service from first boot
inherit systemd
SYSTEMD_SERVICE:${PN} = "mosquitto.service"
SYSTEMD_AUTO_ENABLE:${PN} = "enable"
