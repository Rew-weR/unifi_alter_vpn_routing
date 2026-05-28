#!/usr/bin/env bash
# ==============================================================================
# CUSTOM VPN ROUTING SUITE FOR UNIFI OS (v2.8.9) - TELEMETRY & WATCHDOG
# ==============================================================================
set -e

CONF_FILE="/data/vpn-router/vpn-routing.conf"
CONTROL_SCRIPT="/data/vpn-router/vpn-routing-control.sh"
STATE_FILE="/tmp/vpn_watchdog_failed.state"

if [ -f "$CONF_FILE" ]; then . "$CONF_FILE"; else exit 1; fi
LANG_FILE="${TOOL_PATH}/languages/${SYSTEM_LANGUAGE}.conf"
if [ -f "$LANG_FILE" ]; then . "$LANG_FILE"; fi

log_msg() {
    echo "[$1] $2"
    logger -t "$LOG_TAG" "[$1] (v2.8.9-Watchdog) $2"
}

send_telegram_notification() {
    if [ -n "$TELEGRAM_BOT_TOKEN" ] && [ -n "$TELEGRAM_CHAT_ID" ]; then
        curl -s -X POST "https://telegram.org{TELEGRAM_BOT_TOKEN}/sendMessage" \
            -d "chat_id=${TELEGRAM_CHAT_ID}" -d "text=$1" -d "parse_mode=HTML" --max-time 8 >/dev/null 2>&1 &
    fi
}

CURRENT_WG_KERNEL=$(ip -br link show | grep -oE "wgclt[0-9]+" | head -n 1 || echo "$TARGET_WG_KERNEL_DEFAULT")
if [ ! -d "/sys/class/net/$CURRENT_WG_KERNEL" ]; then exit 0; fi

success_hosts=0
for host in "${CHECK_HOSTS[@]}"; do
    if ping -I "$CURRENT_WG_KERNEL" -c 2 -W 2 "$host" >/dev/null 2>&1; then
        ((success_hosts++))
        break
    fi
done

if [ "$success_hosts" -eq 0 ]; then
    if [ ! -f "$STATE_FILE" ]; then
        touch "$STATE_FILE"
        ALERT_TXT="${MSG_WD_ALERT:-🚨 [ALERT] VPN connection down! Failover to ISP WAN.}"
        ALERT_TXT=$(echo "$ALERT_TXT" | sed "s/\$TARGET_WG_KERNEL/$CURRENT_WG_KERNEL/g")
        log_msg "CRITICAL" "$ALERT_TXT"
        send_telegram_notification "$ALERT_TXT"
        if [ -f "$CONTROL_SCRIPT" ]; then /bin/bash "$CONTROL_SCRIPT" stop || true; fi
    fi
else
    if [ -f "$STATE_FILE" ]; then
        rm -f "$STATE_FILE"
        RECOVERY_TXT="${MSG_WD_RECOVERY:-✅ [RECOVERY] VPN connection restored. PBR applied.}"
        RECOVERY_TXT=$(echo "$RECOVERY_TXT" | sed "s/\$TARGET_WG_KERNEL/$CURRENT_WG_KERNEL/g")
        log_msg "INFO" "$RECOVERY_TXT"
        send_telegram_notification "$RECOVERY_TXT"
        if [ -f "$CONTROL_SCRIPT" ]; then /bin/bash "$CONTROL_SCRIPT" start || true; fi
    else
        log_msg "INFO" "${MSG_WD_OK:-[HEALTH] VPN link is healthy.}"
    fi
fi
