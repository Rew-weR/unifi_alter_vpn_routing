#!/usr/bin/env bash

# ==============================================================================
# CUSTOM VPN ROUTING SUITE FOR UNIFI OS (v3.3.0-Stable) - BYPASS CORE MODULE
# ==============================================================================
# Ядерный модуль обработки списков. Выполняет пакетную конвертацию IP/CIDR 
# в ipset структуры ядра Linux и управляет правилами fwmark маршрутизации.
# ==============================================================================

set -e

# --- Базовые пути и импорт конфигурации ---
CONF_FILE="/data/vpn-router/vpn-routing.conf"
FWMARK_ID="0x99"
PREF_BYPASS_RULE=1500

if [ -f "$CONF_FILE" ]; then
    . "$CONF_FILE"
else
    echo "[CRITICAL] Configuration file $CONF_FILE not found in bypass module!"
    exit 1
fi

# Единый фреймворк логирования (syslog)
log_msg() {
    logger -t "$LOG_TAG" "[$1] (v3.3.0-BypassCore) $2"
}

# Функция генерации валидного имени ipset из пути к файлу
get_set_name() {
    local base_name
    base_name=$(basename "$1" | tr -cd 'a-zA-Z0-9_-')
    echo "vpn_${base_name:0:27}" # Ограничение ядра Linux на длину имени ipset
}

# ==============================================================================
# РЕЖИМ ЗАПУСКА: ИНТЕГРАЦИЯ И СБОРКА СПИСКА (START)
# ==============================================================================
start_bypass_file() {
    local file_in="$1"
    
    if [ ! -f "$file_in" ] || [ ! -s "$file_in" ]; then
        return 0
    fi

    # --- ЖЕЛЕЗНАЯ ЗАЩИТА: ДИНАМИЧЕСКИЙ ПЕРЕВОД ID ТАБЛИЦЫ В ЧИСЛО ---
    local unifi_route_line
    unifi_route_line=$(ip route show table all | grep -E "wgclt[0-9]+" | head -n 1 || true)
    local detected_table_id=""
    local detected_kernel_iface=""

    if [ -n "$unifi_route_line" ]; then
        local raw_table_cell
        raw_table_cell=$(echo "$unifi_route_line" | awk '{print $3}')
        if [[ "$raw_table_cell" == *.* ]]; then
            detected_table_id=$(echo "$raw_table_cell" | cut -d'.' -f1)
            detected_kernel_iface=$(echo "$raw_table_cell" | cut -d'.' -f2)
        fi
    fi

    TARGET_WG_KERNEL="${detected_kernel_iface:-wgclt4}"
    TARGET_PURE_TABLE_ID="${detected_table_id:-178}"
    
    # Если на входе не число, принудительно ставим эталонные 178
    if ! [[ "$TARGET_PURE_TABLE_ID" =~ ^[0-9]+$ ]]; then 
        TARGET_PURE_TABLE_ID="178" 
    fi

    local set_name
    set_name=$(get_set_name "$file_in")
    log_msg "INFO" "Инициализация списка: $set_name ($file_in). Таблица: $TARGET_PURE_TABLE_ID"

    # 1. Создаем ipset типа hash:net (для поддержки одиночных IP и подсетей CIDR)
    if ! ipset list "$set_name" >/dev/null 2>&1; then
        ipset create "$set_name" hash:net hashsize 4096 maxelem 131072
    fi

    # 2. Высокоскоростная пакетная конвертация данных через AWK
    log_msg "INFO" "Пакетная конвертация данных через AWK..."
    local tmp_restore="/tmp/${set_name}_restore.txt"
    echo "create $set_name hash:net hashsize 4096 maxelem 131072 -exist" > "$tmp_restore"

    awk -v sname="$set_name" '
        {
            sub(/#.*/, "");         # Вырезаем кастомные комментарии
            gsub(/[ \t\r\n]/, "");   # Удаляем пробелы, табы и Windows-символы CRLF (\r)
            if ($0 ~ /^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}(\/[0-9]{1,2})?$/) {
                print "add " sname " " $0 " -exist"
            }
        }
    ' "$file_in" >> "$tmp_restore"

    # Атомарно заливаем массив в память ядра Linux
    ipset restore < "$tmp_restore"
    rm -f "$tmp_restore"

    # 3. Настройка перехвата и маркировки трафика через iptables mangle
    if ! iptables -t mangle -C PREROUTING -m set --match-set "$set_name" dst -j MARK --set-xmark "${FWMARK_ID}/0xffffffff" >/dev/null 2>&1; then
        iptables -t mangle -A PREROUTING -m set --match-set "$set_name" dst -j MARK --set-xmark "${FWMARK_ID}/0xffffffff"
    fi

    # 4. Абсолютно безопасное атомарное добавление правила в ip rule
    # Исключает ошибку "RTNETLINK answers: File exists" путем мягкой перезаписи правила
    ip rule del fwmark "$FWMARK_ID" pref "$PREF_BYPASS_RULE" table "$TARGET_PURE_TABLE_ID" 2>/dev/null || true
    ip rule add fwmark "$FWMARK_ID" pref "$PREF_BYPASS_RULE" table "$TARGET_PURE_TABLE_ID"

    log_msg "INFO" "Список '$set_name' успешно интегрирован в ядро."
}

# ==============================================================================
# РЕЖИМ ДЕМОНТАЖА: ОЧИСТКА КОНКРЕТНОГО СПИСКА (STOP)
# ==============================================================================
stop_bypass_file() {
    local file_in="$1"
    if [ ! -f "$file_in" ]; then return 0; fi

    local set_name
    set_name=$(get_set_name "$file_in")
    log_msg "INFO" "Удаление правил ядра для списка: $set_name"

    iptables -t mangle -D PREROUTING -m set --match-set "$set_name" dst -j MARK --set-xmark "${FWMARK_ID}/0xffffffff" >/dev/null 2>&1 || true
    ipset destroy "$set_name" >/dev/null 2>&1 || true
}

# ==============================================================================
# ГЛОБАЛЬНАЯ ТОТАЛЬНАЯ ЗАЧИСТКА ВСЕХ СТРУКТУР (CLEAN)
# ==============================================================================
global_clean() {
    log_msg "INFO" "Запуск тотальной очистки подсистемы маркировки обхода..."

    # Удаляем кастомное правило маршрутизации
    while ip rule del fwmark "$FWMARK_ID" pref "$PREF_BYPASS_RULE" 2>/dev/null; do :; done

    # Поиск и уничтожение всех динамических ipset с нашим префиксом vpn_
    local active_sets
    active_sets=$(ipset list -n | grep "^vpn_" || true)

    for set_item in $active_sets; do
        iptables -t mangle -D PREROUTING -m set --match-set "$set_item" dst -j MARK --set-xmark "${FWMARK_ID}/0xffffffff" >/dev/null 2>&1 || true
        ipset destroy "$set_item" >/dev/null 2>&1 || true
    done
}

# --- Логика обработки аргументов ---
case "$1" in
    start)
        if [ -z "$2" ]; then exit 1; fi
        start_bypass_file "$2"
        ;;
    stop)
        if [ -z "$2" ]; then exit 1; fi
        stop_bypass_file "$2"
        ;;
    clean)
        global_clean
        ;;
    *)
        echo "Usage: $0 {start <file>|stop <file>|clean}"
        exit 1
        ;;
esac
