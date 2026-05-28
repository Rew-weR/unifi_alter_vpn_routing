#!/usr/bin/env bash
# ==============================================================================
# CUSTOM VPN ROUTING SUITE FOR UNIFI OS (v2.8.9) - BYPASS CORE MODULE
# ==============================================================================
set -e

CONF_FILE="/data/vpn-router/vpn-routing.conf"
if [ -f "$CONF_FILE" ]; then . "$CONF_FILE"; else exit 1; fi

FWMARK_ID="0x99"
PREF_BYPASS_RULE=1500

log_msg() {
    logger -t "$LOG_TAG" "[$1] (v2.8.9-BypassCore) $2"
}

if [ -z "$TARGET_PURE_TABLE_ID" ]; then TARGET_PURE_TABLE_ID="178"; fi

get_set_name() {
    local base_name=$(basename "$1" | tr -cd 'a-zA-Z0-9_-')
    echo "vpn_${base_name:0:27}"
}

start_bypass_file() {
    local file_in="$1"
    
    if [ ! -f "$file_in" ] || [ ! -s "$file_in" ]; then
        return 0
    fi

    # --- ДИНАМИЧЕСКИЙ ПОИСК ИНТЕРФЕЙСА И ID ТАБЛИЦЫ ---
    local unifi_route_line
    unifi_route_line=$(ip route show table all | grep -E "wgclt[0-9]+" | head -n 1 || true)
    local detected_table_id=""
    local detected_kernel_iface=""

    if [ -n "$unifi_route_line" ]; then
        local raw_table_cell
        raw_table_cell=$(echo "$unifi_route_line" | awk '{print $3}')
        if [[ "$raw_table_cell" == *"."* ]]; then
            detected_table_id=$(echo "$raw_table_cell" | cut -d'.' -f1)
            detected_kernel_iface=$(echo "$raw_table_cell" | cut -d'.' -f2)
        fi
    fi

    TARGET_WG_KERNEL="${detected_kernel_iface:-wgclt4}"
    TARGET_PURE_TABLE_ID="${detected_table_id:-178}"
    if ! [[ "$TARGET_PURE_TABLE_ID" =~ ^[0-9]+$ ]]; then TARGET_PURE_TABLE_ID="178"; fi

    local set_name
    set_name=$(get_set_name "$file_in")
    log_msg "INFO" "Инициализация списка: $set_name ($file_in). Таблица: $TARGET_PURE_TABLE_ID"

    # 1. Создаем ipset, если его нет
    if ! ipset list "$set_name" >/dev/null 2>&1; then
        ipset create "$set_name" hash:net hashsize 4096 maxelem 131072
    fi

    # --------------------------------------------------------------------------
    # СВЕРХБЫСТРЫЙ И БЕЗОПАСНЫЙ ПАРСИНГ ЧЕРЕЗ AWK (ЗАМЕНА ЗАВИСШЕГО ЦИКЛА)
    # --------------------------------------------------------------------------
    log_msg "INFO" "Пакетная конвертация данных через AWK..."
    
    # Формируем временный файл команд для утилиты ipset restore
    local tmp_restore="/tmp/${set_name}_restore.txt"
    echo "create $set_name hash:net hashsize 4096 maxelem 131072 -exist" > "$tmp_restore"

    # С помощью awk мгновенно вычищаем комментарии, пробелы, символы Windows (CRLF)
    # и генерируем пачку команд "add имя_сета IP"
    awk -v sname="$set_name" '
        {
            sub(/#.*/, "");         # Удаляем комментарии
            gsub(/[ \t\r\n]/, "");   # Удаляем пробелы, табуляции и символы возврата каретки \r
            if ($0 ~ /^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}(\/[0-9]{1,2})?$/) {
                print "add " sname " " $0 " -exist"
            }
        }
    ' "$file_in" >> "$tmp_restore"

    # Заливаем весь файл в ядро одним атомарным запросом (займет доли секунды)
    ipset restore < "$tmp_restore"
    rm -f "$tmp_restore"
    # --------------------------------------------------------------------------

    # 2. Настройка маркировки iptables
    if ! iptables -t mangle -C PREROUTING -m set --match-set "$set_name" dst -j MARK --set-xmark "${FWMARK_ID}/0xffffffff" >/dev/null 2>&1; then
        iptables -t mangle -A PREROUTING -m set --match-set "$set_name" dst -j MARK --set-xmark "${FWMARK_ID}/0xffffffff"
    fi

    # 3. Добавление правила маршрутизации маркированного трафика
    if ! ip rule list | grep -F "fwmark $FWMARK_ID pref $PREF_BYPASS_RULE table $TARGET_PURE_TABLE_ID" >/dev/null 2>&1; then
        ip rule add fwmark "$FWMARK_ID" pref "$PREF_BYPASS_RULE" table "$TARGET_PURE_TABLE_ID"
    fi
    
    log_msg "INFO" "Список '$set_name' успешно интегрирован в ядро."
}


stop_bypass_file() {
    local file_in="$1"
    if [ ! -f "$file_in" ]; then return 0; fi
    local set_name=$(get_set_name "$file_in")
    iptables -t mangle -D PREROUTING -m set --match-set "$set_name" dst -j MARK --set-xmark "${FWMARK_ID}/0xffffffff" >/dev/null 2>&1 || true
    ipset destroy "$set_name" >/dev/null 2>&1 || true
}

global_clean() {
    while ip rule del fwmark "$FWMARK_ID" pref "$PREF_BYPASS_RULE" table "$TARGET_PURE_TABLE_ID" 2>/dev/null; do :; done
    local active_sets=$(ipset list -n | grep "^vpn_" || true)
    for set in $active_sets; do
        iptables -t mangle -D PREROUTING -m set --match-set "$set" dst -j MARK --set-xmark "${FWMARK_ID}/0xffffffff" >/dev/null 2>&1 || true
        ipset destroy "$set" >/dev/null 2>&1 || true
    done
}

case "$1" in
    start) start_bypass_file "$2" ;;
    stop) stop_bypass_file "$2" ;;
    clean) global_clean ;;
    *) echo "Usage: $0 {start <file>|stop <file>|clean}"; exit 1 ;;
esac
