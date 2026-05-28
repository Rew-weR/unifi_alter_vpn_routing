#!/usr/bin/env bash
# ==============================================================================
# CUSTOM VPN ROUTING SUITE FOR UNIFI OS (v2.8.9) - BYPASS LOADER
# ==============================================================================
set -e

CONF_FILE="/data/vpn-router/vpn-routing.conf"
if [ -f "$CONF_FILE" ]; then . "$CONF_FILE"; else exit 1; fi

LANG_FILE="${TOOL_PATH}/languages/${SYSTEM_LANGUAGE}.conf"
if [ -f "$LANG_FILE" ]; then . "$LANG_FILE"; fi

log_msg() {
    local level="$1" message="$2"
    echo "[$level] $message"
    logger -t "$LOG_TAG" "[$level] (v2.8.9-Loader) $message"
}

BYPASS_MODULE="${TOOL_PATH}/vpn-bypass-module.sh"

load_bypass_logic() {
    log_msg "INFO" "${MSG_STARTING_BYPASS:-Инициализация списков обхода...}"
    if [ ! -f "$BYPASS_MODULE" ]; then exit 1; fi
    chmod +x "$BYPASS_MODULE"

    if [ -z "$TARGET_PURE_TABLE_ID" ]; then
        local detected_iface=$(ip -br link show | grep -oE "wgclt[0-9]+" | head -n 1 || echo "wgclt4")
        local unifi_table_raw=$(ip route show table all | grep -m1 "$detected_iface" | awk '{print $3}' || echo "178")
        TARGET_PURE_TABLE_ID=$(echo "$unifi_table_raw" | cut -d'.' -f1)
    fi
    export TARGET_PURE_TABLE_ID

    if [ -d "$BYPASS_PARTS_DIR" ] && [ "$(ls -A "$BYPASS_PARTS_DIR" 2>/dev/null)" ]; then
        for part_file in "$BYPASS_PARTS_DIR"/*; do
            [ -e "$part_file" ] || continue
            /bin/bash "$BYPASS_MODULE" start "$part_file" || true
        done
    fi

    if [ -f "$BYPASS_HOSTS_FILE" ] && [ -s "$BYPASS_HOSTS_FILE" ]; then
        /bin/bash "$BYPASS_MODULE" start "$BYPASS_HOSTS_FILE" || true
    fi
}

unload_bypass_logic() {
    log_msg "INFO" "${MSG_STOPPING_BYPASS:-Очистка списков обхода...}"
    if [ -f "$BYPASS_MODULE" ]; then
        if [ -d "$BYPASS_PARTS_DIR" ]; then
            for part_file in "$BYPASS_PARTS_DIR"/*; do [ -e "$part_file" ] && /bin/bash "$BYPASS_MODULE" stop "$part_file" 2>/dev/null || true; done
        fi
        if [ -f "$BYPASS_HOSTS_FILE" ]; then /bin/bash "$BYPASS_MODULE" stop "$BYPASS_HOSTS_FILE" 2>/dev/null || true; fi
        /bin/bash "$BYPASS_MODULE" clean 2>/dev/null || true
    fi
}

case "$1" in
    start) load_bypass_logic ;;
    stop|clean) unload_bypass_logic ;;
    restart) unload_bypass_logic; load_bypass_logic ;;
    *) echo "Usage: $0 {start|stop|clean|restart}"; exit 1 ;;
esac
