#!/usr/bin/env bash
# ==============================================================================
# CUSTOM VPN ROUTING SUITE FOR UNIFI OS (v2.8.9) - MAIN CONTROLLER
# ==============================================================================
set -e

CONF_FILE="/data/vpn-router/vpn-routing.conf"
if [ -f "$CONF_FILE" ]; then . "$CONF_FILE"; else exit 1; fi

LANG_FILE="${TOOL_PATH}/languages/${SYSTEM_LANGUAGE}.conf"
if [ -f "$LANG_FILE" ]; then . "$LANG_FILE"; fi

log_msg() {
    local level="$1" message="$2"
    echo "[$level] $message"
    logger -t "$LOG_TAG" "[$level] (v2.8.9-Control) $message"
}

detect_unifi_parameters() {
    log_msg "INFO" "Выполнение динамического сканирования сетевого стека UniFi OS..."
    local detected_iface detected_ip unifi_table_raw
    detected_iface=$(ip -br link show | grep -oE "wgclt[0-9]+" | head -n 1 || true)
    
    if [ -n "$detected_iface" ]; then
        TARGET_WG_KERNEL="$detected_iface"
    else
        TARGET_WG_KERNEL="${TARGET_WG_KERNEL_DEFAULT:-wgclt4}"
    fi

    detected_ip=$(ip addr show "$TARGET_WG_KERNEL" 2>/dev/null | grep -oE 'inet [0-9.]+' | awk '{print $2}' || true)
    TARGET_WG_STATIC_IP="${detected_ip:-${TARGET_WG_STATIC_IP_DEFAULT:-10.151.0.3}}"

    unifi_table_raw=$(ip route show table all | grep -m1 "$TARGET_WG_KERNEL" | awk '{print $3}' || true)
    if [[ "$unifi_table_raw" == *"."* ]]; then
        TARGET_PURE_TABLE_ID=$(echo "$unifi_table_raw" | cut -d'.' -f1)
    else
        TARGET_PURE_TABLE_ID="${TARGET_PURE_TABLE_ID_DEFAULT:-178}"
    fi
    
    if ! [[ "$TARGET_PURE_TABLE_ID" =~ ^[0-9]+$ ]]; then TARGET_PURE_TABLE_ID="178"; fi
    log_msg "INFO" "Параметры согласованы: Таблица=$TARGET_PURE_TABLE_ID, Интерфейс=$TARGET_WG_KERNEL"
}

backup_kernel_state() {
    local timestamp=$(date +%Y%m%d%H%M%S)
    mkdir -p "$BACKUP_DIR"
    ip rule list > "${BACKUP_DIR}/rules_${timestamp}.bak"
    ip route show table main > "${BACKUP_DIR}/routes_main_${timestamp}.bak"
    ls -t "${BACKUP_DIR}"/rules_*.bak 2>/dev/null | tail -n +$((MAX_BACKUPS + 1)) | xargs rm -f 2>/dev/null || true
    ls -t "${BACKUP_DIR}"/routes_main_*.bak 2>/dev/null | tail -n +$((MAX_BACKUPS + 1)) | xargs rm -f 2>/dev/null || true
}

start_routing() {
    log_msg "INFO" "$MSG_STARTING"
    detect_unifi_parameters
    backup_kernel_state

    for subnet in "${LOCAL_SUPERNETS[@]}"; do
        if ! ip rule list | grep -F "from all to $subnet pref $PREF_LOCAL_ISOLATION" >/dev/null 2>&1; then
            ip rule add to "$subnet" pref "$PREF_LOCAL_ISOLATION" table main
        fi
    done

    for net_info in "${SRC_NETWORKS[@]}"; do
        IFS=':' read -r iface subnet type <<< "$net_info"
        if [ "$type" == "PBR_AND_DC" ]; then
            for dc_subnet in "${DC_REMOTE_SUBNETS[@]}"; do
                if ! ip rule list | grep -F "from $subnet to $dc_subnet pref $PREF_IPSEC_INTERCEPT" >/dev/null 2>&1; then
                    ip rule add from "$subnet" to "$dc_subnet" pref "$PREF_IPSEC_INTERCEPT" table main
                fi
            done
        fi
    done

    local current_pref="$PREF_VPN_PBR_BASE"
    for net_info in "${SRC_NETWORKS[@]}"; do
        IFS=':' read -r iface subnet type <<< "$net_info"
        if ! ip rule list | grep -F "from $subnet pref $current_pref" >/dev/null 2>&1; then
            ip rule add from "$subnet" pref "$current_pref" table "$TARGET_PURE_TABLE_ID"
        fi
        ((current_pref++))
    done

    if ! ip route show table "$TARGET_PURE_TABLE_ID" | grep -q "default"; then
        ip route add default dev "$TARGET_WG_KERNEL" table "$TARGET_PURE_TABLE_ID" || true
    fi

    if [ -f "${TOOL_PATH}/vpn-bypass-loader.sh" ]; then
        /bin/bash "${TOOL_PATH}/vpn-bypass-loader.sh" start || true
    fi
    log_msg "INFO" "Правила ядра успешно применены."
}

clean_routing() {
    log_msg "INFO" "$MSG_CLEANING"
    if [ -f "${TOOL_PATH}/vpn-bypass-loader.sh" ]; then /bin/bash "${TOOL_PATH}/vpn-bypass-loader.sh" stop || true; fi
    for subnet in "${LOCAL_SUPERNETS[@]}"; do while ip rule del to "$subnet" pref "$PREF_LOCAL_ISOLATION" table main 2>/dev/null; do :; done; done
    for dc_subnet in "${DC_REMOTE_SUBNETS[@]}"; do while ip rule del to "$dc_subnet" pref "$PREF_IPSEC_INTERCEPT" table main 2>/dev/null; do :; done; done
    
    local current_pref
    for ((current_pref=PREF_VPN_PBR_BASE; current_pref<(PREF_VPN_PBR_BASE + ${#SRC_NETWORKS[@]} + 10); current_pref++)); do
        while ip rule del pref "$current_pref" 2>/dev/null; do :; done
    done
    log_msg "INFO" "Очистка ядра завершена."
}

case "$1" in
    start) start_routing ;;
    stop|clean) clean_routing ;;
    restart) clean_routing; start_routing ;;
    *) echo "Usage: $0 {start|stop|clean|restart}"; exit 1 ;;
esac
