# docs/images

Screenshots taken from the live CCLRTE system running on Raspberry Pi 5 Model B Rev 1.1, kernel `6.6.63-cclrte-xenomai`, 2026-06-09.

Referenced in `USER_GUIDE.md`, `ARCHITECTURE.md`, and the root `README.md` using URL-encoded paths (spaces → `%20`).

| File | What it shows | Used in |
|------|--------------|---------|
| `Webui Dashboard.png` | Main dashboard — all 5 services ACTIVE, RT PASS 11 µs, CPU isolation (CPU2=0% CPU3=80%), NTP synced, Xenomai Cobalt | README, USER_GUIDE, ARCHITECTURE |
| `Webui Network Configuration.png` | Network page — eth0 static 192.168.2.100/24, wlan0 DHCP 192.168.1.108, SSH key panel | USER_GUIDE |
| `Webui Industrial Communication configuration.png` | Protocols page — EtherCAT ACTIVE CPU2 SCHED_FIFO 90 ec_generic MAC shown, PROFINET + Modbus INACTIVE, MQTT ACTIVE | USER_GUIDE |
| `Webui Codesys Runtime Configuration.png` | CODESYS runtime page — 500 µs cycle, SCHED_FIFO 80 CPU3, RT PASS 11 µs, service log | USER_GUIDE, ARCHITECTURE |
| `Webui System configuration.png` | System page — RT verify PASS 11 µs, CPU2/CPU3 idle+load table, kernel 6.6.63-cclrte-xenomai, 50.7 °C | USER_GUIDE, ARCHITECTURE |
| `Codesys Load Test configuration.png` | CODESYS IDE variable watch — FB_LoadTest 100% load: 100k iters, xOverrun FALSE, udiElapsedMs 0 | README, USER_GUIDE |
| `Codesys Load Test Results.png` | CODESYS Task Configuration Monitor — 500 µs cycle, avg 372 µs, max 402 µs, Core 3 | README, USER_GUIDE |
