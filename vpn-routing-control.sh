#!/bin/sh

# ===================================================================
# SCRIPT VERSION: v2.7.0-Stable (Enterprise IPSet Core Controller)
# DESCRIPTION: Управление интернет-трафиком (32600+), IPSec и плагином IPSet
# ===================================================================

ROUTING_TOOL_PATH="/data/vpn-router"
CONFIG_FILE="$ROUTING_TOOL_PATH/vpn-routing.conf"
BACKUPS_DIRECTORY="$ROUTING_TOOL_PATH/routes-backup"
BYPASS_PLUGIN="$ROUTING_TOOL_PATH/vpn-bypass-module.sh"
SYSLOG_IDENTIFIER="CustomVPNRouting"
SCRIPT_VERSION="2.7.0-Stable"

log_msg() {
    local level="$1"
    local msg="$2"
    echo "[$level] $msg"
    logger -t "$SYSLOG_IDENTIFIER" "[$level] (v$SCRIPT_VERSION) $msg"
}

send_telegram() {
    local message="$1"
    [ "$ENABLE_TELEGRAM" != "true" ] && return 0
    [ -z "$TELEGRAM_BOT_TOKEN" ] || [ -z "$TELEGRAM_CHAT_ID" ] && return 0
    curl -s -X POST "https://telegram.org{TELEGRAM_BOT_TOKEN}/sendMessage" \
        -d "chat_id=${TELEGRAM_CHAT_ID}" \
        -d "text=🤖 UDM SE: $message" >/dev/null 2>&1 &
}

make_routing_backup() {
    local timestamp=$(date +%Y%m%d_%H%M%S)
    mkdir -p "$BACKUPS_DIRECTORY"
    ip rule list > "$BACKUPS_DIRECTORY/ip_rules_$timestamp.bak"
    ip route show table main > "$BACKUPS_DIRECTORY/route_main_$timestamp.bak"
    [ -n "$EXIT_NODE_ROUTING_TABLE" ] && ip rule list | grep -q "lookup $EXIT_NODE_ROUTING_TABLE" && ip route show table "$EXIT_NODE_ROUTING_TABLE" > "$BACKUPS_DIRECTORY/route_vpn_$timestamp.bak" 2>/dev/null
    iptables -t nat -S > "$BACKUPS_DIRECTORY/iptables_nat_$timestamp.bak"
    
    cd "$BACKUPS_DIRECTORY" 2>/dev/null && ls -t *.bak 2>/dev/null | tail -n +41 | xargs rm -f 2>/dev/null
}

if [ ! -f "$CONFIG_FILE" ]; then exit 1; fi
. "$CONFIG_FILE"
LANG_FILE="$ROUTING_TOOL_PATH/languages/${SYSTEM_LANGUAGE:-en}.conf"
[ -f "$LANG_FILE" ] && . "$LANG_FILE"

get_vpn_params() {
    EXIT_NODE_SYSTEM_INTERFACE=$(ip -4 addr show | grep "$EXIT_NODE_INTERNAL_IP" | awk '{print $NF}')
    if [ -z "$EXIT_NODE_SYSTEM_INTERFACE" ]; then
        EXIT_NODE_SYSTEM_INTERFACE=$(ip link show | grep -o 'wgclt[0-9]*' | head -n 1)
        if [ -n "$EXIT_NODE_SYSTEM_INTERFACE" ]; then
            EXIT_NODE_INTERNAL_IP=$(ip -4 addr show dev "$EXIT_NODE_SYSTEM_INTERFACE" | grep -oE 'inet [0-9.]+' | awk '{print $2}')
        fi
    fi
    if [ -n "$EXIT_NODE_SYSTEM_INTERFACE" ] && [ -n "$EXIT_NODE_INTERNAL_IP" ]; then
        raw_table=$(ip rule list | grep "from $EXIT_NODE_INTERNAL_IP" | awk '{print $NF}')
        if [ -z "$raw_table" ] || [ "$raw_table" = "main" ]; then
            raw_table=$(ip rule list | grep "lookup" | grep "$EXIT_NODE_SYSTEM_INTERFACE" | awk '{print $NF}')
        fi
        EXIT_NODE_ROUTING_TABLE=$(echo "$raw_table" | cut -d'.' -f1)
    fi
}

get_config_path() {
    CONF_PATH="/data/udapi-config/ubios-udapi-server/config.json"
    [ ! -f "$CONF_PATH" ] && CONF_PATH=$(ls /tmp/udapi-net-cfg*.json 2>/dev/null | head -n 1)
}

get_dc_subnets() {
    [ "$ENABLE_DATACENTER_ROUTING" != "true" ] && return 0
    get_config_path
    if [ -n "$CONF_PATH" ] && [ -f "$CONF_PATH" ]; then
        DATACENTER_REMOTE_SUBNETS=$(awk -v name="$DC_IPSEC_TUNNEL_NAME" '$0 ~ name {found=1} found && /"remoteSubnets"/ {nest=1; next} nest {if (/{|\[/) nest++; if (/}|\]/) nest--; if (nest==0) {found=0; exit}; gsub(/[^0-9./]/, ""); if ($0 != "") print $0}' "$CONF_PATH" 2>/dev/null)
    fi
    [ -z "$DATACENTER_REMOTE_SUBNETS" ] && DATACENTER_REMOTE_SUBNETS="172.20.150.0/22 172.20.154.0/24 172.20.155.0/24"
}

check_internet() {
    local interface=$1
    log_msg "INFO" "$MSG_PING_TEST $interface..."
    for host in $CHECK_HOSTS; do
        if ping -I "$interface" -c 2 -W 2 "$host" >/dev/null 2>&1; then return 0; fi
    done
    return 1
}

case "$1" in
    start)
        [ "$2" != "nodelay" ] && sleep 15
        get_vpn_params
        [ "$ENABLE_DATACENTER_ROUTING" = "true" ] && get_dc_subnets

        if [ -z "$EXIT_NODE_SYSTEM_INTERFACE" ] || [ -z "$EXIT_NODE_ROUTING_TABLE" ]; then
            log_msg "ERROR" "$MSG_ERR_PARAMS"; send_telegram "$MSG_ERR_TG"; exit 1
        fi

        make_routing_backup

        log_msg "INFO" "Предварительная автоматическая очистка пулов правил ядра..."
        # Очищаем диапазоны: 900+ (Bypass), 32600+ (Internet), 10000+ (DC)
        for p in $(seq 900 999) $(seq 32600 32699) $(seq 10000 10099); do
            while ip rule del pref $p 2>/dev/null; do :; done
        done

        if ! check_internet "$EXIT_NODE_SYSTEM_INTERFACE"; then
            log_msg "ERROR" "$MSG_ERR_PING"; send_telegram "$MSG_ERR_PING_TG"; exit 1
        fi

        log_msg "INFO" "$MSG_START"
        log_msg "INFO" "Interface: $EXIT_NODE_SYSTEM_INTERFACE -> Table: $EXIT_NODE_ROUTING_TABLE"

        # --- БЛОК 1. МАРШРУТИЗАЦИЯ В ИНТЕРНЕТ (Диапазон 32600+, под нативным PBR) ---
        local_pref=32600
        for net in $INTERNET_FORWARD_NETS; do
            [ -z "$net" ] && continue
            ip rule add from "$net" to 172.20.0.0/16 pref $local_pref table main; local_pref=$((local_pref + 1))
            ip rule add from "$net" to 192.168.0.0/16 pref $local_pref table main; local_pref=$((local_pref + 1))
            ip rule add from "$net" pref $local_pref table "$EXIT_NODE_ROUTING_TABLE"; local_pref=$((local_pref + 1))
        done

        # --- БЛОК 2. МАРШРУТИЗАЦИЯ В ДАТА-ЦЕНТР (Диапазон 10000+) ---
        if [ "$ENABLE_DATACENTER_ROUTING" = "true" ]; then
            log_msg "INFO" "$MSG_DC_ON"
            dc_pref=10000
            for src_net in $DATACENTER_ALLOWED_NETS; do
                [ -z "$src_net" ] && continue
                for dst_net in $DATACENTER_REMOTE_SUBNETS; do
                    [ -z "$dst_net" ] && continue
                    ip rule add from "$src_net" to "$dst_net" pref $dc_pref table main; dc_pref=$((dc_pref + 1))
                done
            done
        else
            log_msg "INFO" "$MSG_DC_OFF"
        fi
        
        # --- БЛОК 3. АКТИВАЦИЯ ПЛАГИНА ВЫСОКОСКОРОСТНЫХ ИСКЛЮЧЕНИЙ IPSET ---
        if [ -f "$BYPASS_PLUGIN" ]; then
            . "$BYPASS_PLUGIN" start
        fi
        
        log_msg "INFO" "$MSG_SUCCESS"
        send_telegram "$MSG_SUCCESS_TG"
        ;;
        
    stop|clean)
        # Удаление всех кастомных правил из таблиц ядра
        for p in $(seq 900 999) $(seq 32600 32699) $(seq 10000 10099); do
            while ip rule del pref $p 2>/dev/null; do :; done
        done
        
        # Деактивация таблицы IPSet внутри плагина
        if [ -f "$BYPASS_PLUGIN" ]; then
            . "$BYPASS_PLUGIN" clean
        fi
        
        log_msg "INFO" "Cleanup completed."
        ;;

    status)
        get_vpn_params
        [ "$ENABLE_DATACENTER_ROUTING" = "true" ] && get_dc_subnets
        echo "====================================================="
        echo "   CUSTOM ROUTING STATUS / СТАТУС МАРШРУТИЗАЦИИ   "
        echo "====================================================="
        echo "Exit Node VPN:           $EXIT_NODE_VPN_NAME ($EXIT_NODE_SYSTEM_INTERFACE)"
        echo "IPSec Datacenter Module: $ENABLE_DATACENTER_ROUTING"
        echo "IPSet Bypass Module:     $ENABLE_BYPASS_MODULE"
        [ "$ENABLE_DATACENTER_ROUTING" = "true" ] && echo "DC Remote Subnets:       $(echo $DATACENTER_REMOTE_SUBNETS | tr '\n' ' ')"
        
        if [ -n "$EXIT_NODE_SYSTEM_INTERFACE" ] && ping -I "$EXIT_NODE_SYSTEM_INTERFACE" -c 1 -W 1 1.1.1.1 >/dev/null 2>&1; then
            echo "Tunnel Connection:       ONLINE / РАБОТАЕТ"
        else
            echo "Tunnel Connection:       ERROR / ОШИБКА"
        fi
        echo "-----------------------------------------------------"
        ip rule list | awk '$1+0 >= 900 && $1+0 <= 999 || $1+0 >= 32600 && $1+0 <= 32699 || $1+0 >= 10000 && $1+0 <= 10099'
        echo "====================================================="
        ;;
    *)
        echo "Usage: $0 {start|stop|clean|status}"
        exit 1
        ;;
esac

