#!/bin/sh

# ===================================================================
# WATCHDOG VERSION: v1.3.0 (IPSet Aware & Decoupled i18n)
# ===================================================================

CONFIG_FILE="/data/vpn-router/vpn-routing.conf"
CONTROL_SCRIPT="/data/vpn-router/vpn-routing-control.sh"

if [ ! -f "$CONFIG_FILE" ]; then exit 0; fi
. "$CONFIG_FILE"
if [ "$ENABLE_WATCHDOG" != "true" ]; then exit 0; fi

LANG_FILE="/data/vpn-router/languages/${SYSTEM_LANGUAGE:-en}.conf"
[ -f "$LANG_FILE" ] && . "$LANG_FILE"

IFACE=$(ip -4 addr show | grep "$EXIT_NODE_INTERNAL_IP" | awk '{print $NF}')
[ -z "$IFACE" ] && IFACE=$(ip link show | grep -o 'wgclt[0-9]*' | head -n 1)

# Проверяем, активна ли наша PBR-маршрутизация в данный момент (проверка пула 32600)
RULES_ACTIVE=$(ip rule list | awk '$1+0 >= 32600 && $1+0 <= 32699' | head -n 1)

check_internet() {
    for host in $CHECK_HOSTS; do
        if ping -I "$1" -c 2 -W 2 "$host" >/dev/null 2>&1; then return 0; fi
    done
    return 1
}

eval "LOG_UP=\"$TEXT_UP\""
eval "LOG_DOWN=\"$TEXT_DOWN\""
eval "TG_TEXT_DOWN=\"$TEXT_TG_DOWN\""

if [ -n "$IFACE" ] && check_internet "$IFACE"; then
    if [ -z "$RULES_ACTIVE" ]; then
        logger -t "VPNWatchdog" "[INFO] $LOG_UP"
        $CONTROL_SCRIPT start nodelay
    fi
else
    if [ -n "$RULES_ACTIVE" ]; then
        logger -t "VPNWatchdog" "[WARNING] $LOG_DOWN"
        $CONTROL_SCRIPT stop
        if [ "$ENABLE_TELEGRAM" = "true" ] && [ -n "$TELEGRAM_BOT_TOKEN" ]; then
            curl -s -X POST "https://telegram.org{TELEGRAM_BOT_TOKEN}/sendMessage" \
                -d "chat_id=${TELEGRAM_CHAT_ID}" \
                -d "text=$TG_TEXT_DOWN" >/dev/null 2>&1 &
        fi
    fi
fi

