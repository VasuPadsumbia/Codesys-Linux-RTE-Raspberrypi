#!/bin/bash
# CCLRTE Active Cooler Fan Control — RPi5 BCM2712
# Author: Vasu Padsumbia
#
# Maintains CPU temperature between 50-60°C using PWM fan speed control.
# RPi5 exposes fan via /sys/class/thermal/cooling_device0 (fan) and
# temperature via /sys/class/thermal/thermal_zone0 (CPU).
#
# Fan states: 0=off, 1=low (~30%), 2=med (~60%), 3=full (100%)

set -uo pipefail

LOG=/var/log/cclrte-fan.log
TEMP_ZONE=/sys/class/thermal/thermal_zone0/temp
FAN_DEVICE=""

TEMP_LOW=50000    # millidegrees — below this temp: reduce fan
TEMP_HIGH=60000   # millidegrees — above this temp: increase fan
TEMP_CRIT=75000   # millidegrees — emergency full speed
POLL_SEC=5

log() { echo "[$(date '+%Y-%m-%dT%H:%M:%S')] FAN-CTRL: $*" | tee -a "$LOG"; }

# ── Find fan cooling device ───────────────────────────────────────────────────
find_fan() {
    for dev in /sys/class/thermal/cooling_device*/; do
        local type
        type=$(cat "${dev}type" 2>/dev/null || echo "")
        if echo "$type" | grep -qi "fan\|pwm"; then
            echo "$dev"
            return 0
        fi
    done
    # RPi5: fan is typically cooling_device0
    [[ -d /sys/class/thermal/cooling_device0 ]] && echo "/sys/class/thermal/cooling_device0"
}

FAN_DEVICE=$(find_fan)
if [[ -z "$FAN_DEVICE" ]]; then
    log "No fan cooling device found — check dtoverlay=gpio-fan or rpi-poe-fan in config.txt"
    exit 1
fi

MAX_STATE=$(cat "${FAN_DEVICE}max_state" 2>/dev/null || echo "3")
log "Fan device: ${FAN_DEVICE} (max_state=${MAX_STATE})"

set_fan() {
    local state="$1"
    [[ "$state" -gt "$MAX_STATE" ]] && state="$MAX_STATE"
    [[ "$state" -lt 0 ]] && state=0
    echo "$state" > "${FAN_DEVICE}cur_state" 2>/dev/null || true
}

get_temp() {
    cat "$TEMP_ZONE" 2>/dev/null || echo "50000"
}

current_state() {
    cat "${FAN_DEVICE}cur_state" 2>/dev/null || echo "0"
}

log "Fan control active — target 50-60°C, polling every ${POLL_SEC}s"

# Initialise fan state from current temperature so the fan starts immediately
# if the system is already warm at service start (avoids hysteresis dead-lock
# where temp sits in 50-60°C band but state is 0 and never increments).
_init_temp=$(get_temp)
if   [[ "$_init_temp" -ge "$TEMP_CRIT" ]];  then set_fan "$MAX_STATE"
elif [[ "$_init_temp" -ge "$TEMP_HIGH" ]];  then set_fan 2
elif [[ "$_init_temp" -ge "$TEMP_LOW" ]];   then set_fan 1
else                                              set_fan 0
fi
log "Init: temp $(( _init_temp / 1000 ))°C → fan state $(current_state)"

PREV_STATE=-1

while true; do
    TEMP=$(get_temp)
    STATE=$(current_state)

    if [[ "$TEMP" -ge "$TEMP_CRIT" ]]; then
        NEW_STATE="$MAX_STATE"
    elif [[ "$TEMP" -ge "$TEMP_HIGH" ]]; then
        # Above 60°C — step up
        NEW_STATE=$(( STATE < MAX_STATE ? STATE + 1 : MAX_STATE ))
    elif [[ "$TEMP" -lt "$TEMP_LOW" ]]; then
        # Below 50°C — step down
        NEW_STATE=$(( STATE > 0 ? STATE - 1 : 0 ))
    else
        # 50-60°C — hysteresis: hold if already running, turn on at min if off
        NEW_STATE=$(( STATE == 0 ? 1 : STATE ))
    fi

    set_fan "$NEW_STATE"

    if [[ "$NEW_STATE" != "$PREV_STATE" ]]; then
        TEMP_C=$(( TEMP / 1000 ))
        log "Temp ${TEMP_C}°C → fan state ${NEW_STATE}/${MAX_STATE}"
        PREV_STATE="$NEW_STATE"
    fi

    sleep "$POLL_SEC"
done
