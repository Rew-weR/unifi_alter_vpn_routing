#!/usr/bin/env bash

# ==============================================================================
# CUSTOM VPN ROUTING SUITE FOR UNIFI OS (v3.2.5-Stable) - BYPASS LOADER
# ==============================================================================
# Модуль интеллектуальной загрузки, проверки каналов и гибридного парсинга.
# Реализует параллельный IP-обход и доменный перехват через встроенный dnsmasq.
# ==============================================================================

set -e

# --- Базовые пути и импорт конфигурации ---
CONF_FILE="/data/vpn-router/vpn-routing.conf"

if [ -f "$CONF_FILE" ]; then
    . "$CONF_FILE"
else
    echo "[CRITICAL] Configuration file $CONF_FILE not found in loader!"
    exit 1
fi

# Подгружаем языковой пакет для вывода локализованных логов
LANG_FILE="${TOOL_PATH}/languages/${SYSTEM_LANGUAGE}.conf"
if [ -f "$LANG_FILE" ]; then
    . "$LANG_FILE"
else
    MSG_STARTING_BYPASS="Инициализация списков обхода..."
    MSG_STOPPING_BYPASS="Очистка списков обхода..."
fi

# Единый фреймворк логирования (syslog + stdout)
log_msg() {
    local level="$1"
    local message="$2"
    echo "[$level] $message"
    logger -t "$LOG_TAG" "[$level] (v3.2.5-Loader) $message"
}

# Скрипт-исполнитель логики обхода (Core Module)
BYPASS_MODULE="${TOOL_PATH}/vpn-bypass-module.sh"

# ==============================================================================
# ЗАПУСК ИНИЦИАЛИЗАЦИИ, ПРОВЕРКИ И ГИБРИДНОГО РАЗВЕРТЫВАНИЯ (START)
# ==============================================================================
load_bypass_logic() {
    log_msg "INFO" "${MSG_STARTING_BYPASS:-Инициализация подсистемы обхода блокировок...}"

    if [ ! -f "$BYPASS_MODULE" ]; then
        log_msg "ERROR" "Исполняемый модуль $BYPASS_MODULE не найден. Обход отключен."
        exit 1
    fi

    chmod +x "$BYPASS_MODULE"

    # --- Динамический детект параметров активного ядра UniFi ---
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
    
    export TARGET_WG_KERNEL
    export TARGET_PURE_TABLE_ID

    # Имя хэш-таблицы ipset (должно строго совпадать с выводом vpn-bypass-module.sh)
    local target_ipset_name="vpn_bypass-hostslist"

    # --------------------------------------------------------------------------
    # ЧАСТЬ 1: ПРИОРИТЕТНАЯ ПРОВЕРКА РУЧНОГО ФАЙЛА И СКАЧИВАНИЕ IP-СПИСКОВ
    # --------------------------------------------------------------------------
    local need_download=true

    if [ -n "$BYPASS_MANUAL_FILE" ] && [ -f "$BYPASS_MANUAL_FILE" ] && [ -s "$BYPASS_MANUAL_FILE" ]; then
        log_msg "INFO" "Обнаружен ручной файл списков: $BYPASS_MANUAL_FILE. Использование локальной копии."
        cp "$BYPASS_MANUAL_FILE" "$BYPASS_HOSTS_FILE"
        need_download=false
    fi

    if [ "$need_download" = true ]; then
        if [ -n "$BYPASS_REMOTE_URL" ]; then
            local remote_host
            remote_host=$(echo "$BYPASS_REMOTE_URL" | awk -F[/:] '{print $4}')
            
            local wan1_interface
            wan1_interface=$(ip route show table all | grep "proto DefaultGateway" | grep -oE "dev [a-zA-Z0-9.-]+" | awk '{print $2}' | head -n 1 || true)
            [ -z "$wan1_interface" ] && wan1_interface="eth8"

            local vpn_interface="$TARGET_WG_KERNEL"
            local selected_interface=""

            log_msg "INFO" "Локальный файл не найден. Проверка доступности удаленного узла $remote_host..."
            
            if curl --interface "$wan1_interface" -sI --max-time 3 "$BYPASS_REMOTE_URL" >/dev/null 2>&1; then
                log_msg "INFO" "Узел доступен напрямую. Для скачивания выбран WAN1 ($wan1_interface)."
                selected_interface="$wan1_interface"
            elif curl --interface "$vpn_interface" -sI --max-time 3 "$BYPASS_REMOTE_URL" >/dev/null 2>&1; then
                log_msg "WARNING" "Узел недоступен через WAN1! Обнаружен доступ через туннель. Выбран VPN ($vpn_interface)."
                selected_interface="$vpn_interface"
            else
                log_msg "ERROR" "Узел полностью недоступен через все каналы связи (WAN1 и VPN)."
            fi

            if [ -n "$selected_interface" ]; then
                log_msg "INFO" "Запуск скачивания списка через интерфейс: $selected_interface"
                if curl --interface "$selected_interface" -sSL "$BYPASS_REMOTE_URL" -o "$BYPASS_HOSTS_FILE" --max-time 25; then
                    log_msg "INFO" "Глобальный файл списков адресов успешно обновлен по сети."
                else
                    log_msg "ERROR" "Сбой curl при скачивании файла через $selected_interface."
                fi
            else
                log_msg "WARNING" "Скачивание невозможно. Будет использована старая рабочая копия (при наличии)."
            fi
        else
            log_msg "WARNING" "BYPASS_REMOTE_URL не задана в vpn-routing.conf. Скачивание пропущено."
        fi
    fi

    # --------------------------------------------------------------------------
    # ЧАСТЬ 2: ОПТИМИЗИРОВАННЫЙ ПЕРЕХВАТ ДОМЕНОВ ЧЕРЕЗ DNSMASQ
    # --------------------------------------------------------------------------
    local domain_file="/data/vpn-router/bypass-domains.list"
    local dnsmasq_conf_dir="/run/dnsmasq.conf.d"
    local custom_dns_conf="${dnsmasq_conf_dir}/custom_vpn_bypass.conf"

    # Гарантируем создание базового ipset до старта dnsmasq
    if ! ipset list "$target_ipset_name" >/dev/null 2>&1; then
        ipset create "$target_ipset_name" hash:net hashsize 4096 maxelem 131072
    fi

    if [ -f "$domain_file" ] && [ -s "$domain_file" ]; then
        log_msg "INFO" "Обнаружен список доменов $domain_file. Настройка динамического ipset..."
        
        mkdir -p "$dnsmasq_conf_dir"
        
        # Высокоскоростная сборка конфигурации dnsmasq через awk в один проход
        echo "# Custom VPN PBR Domain Bypass Rules" > "$custom_dns_conf"
        awk -v ipsetName="$target_ipset_name" '
            {
                sub(/#.*/, ""); # Удаляем комментарии
                gsub(/[ \t\r\n]/, ""); # Сжимаем пробелы и символы Windows
                if (length($0) > 0) {
                    print "ipset=/" $0 "/" ipsetName
                }
            }
        ' "$domain_file" >> "$custom_dns_conf"

        log_msg "INFO" "Мягкое обновление конфигурации службы dnsmasq..."
        killall -HUP dnsmasq || killall dnsmasq || true
    fi

    # --------------------------------------------------------------------------
    # ЧАСТЬ 3: ИНТЕГРАЦИЯ IP-СПИСКОВ И КАСТОМНЫХ СЕГМЕНТОВ В ЯДРО
    # --------------------------------------------------------------------------
    if [ -d "$BYPASS_PARTS_DIR" ] && [ "$(ls -A "$BYPASS_PARTS_DIR" 2>/dev/null)" ]; then
        log_msg "INFO" "Обнаружены кастомные сегменты в $BYPASS_PARTS_DIR. Запуск пакетной обработки..."
        for part_file in "$BYPASS_PARTS_DIR"/*; do
            [ -e "$part_file" ] || continue
            local part_name=$(basename "$part_file")
            log_msg "INFO" "Обработка сегмента обхода: $part_name"
            /bin/bash "$BYPASS_MODULE" start "$part_file" || log_msg "WARNING" "Ошибка обработки сегмента $part_name"
        done
    fi

    if [ -f "$BYPASS_HOSTS_FILE" ] && [ -s "$BYPASS_HOSTS_FILE" ]; then
        log_msg "INFO" "Интеграция глобального списка хостов в таблицы ядра Linux..."
        /bin/bash "$BYPASS_MODULE" start "$BYPASS_HOSTS_FILE" || log_msg "WARNING" "Ошибка обработки глобального списка хостов."
    fi

    log_msg "INFO" "Подсистема обхода блокировок успешно развернута в ядре."
}

# ==============================================================================
# ДЕМОНТАЖ И ОЧИСТКА СПИСКОВ И КОНФИГОВ DNS (STOP)
# ==============================================================================
unload_bypass_logic() {
    log_msg "INFO" "${MSG_STOPPING_BYPASS:-Демонтаж и полная очистка правил обхода блокировок...}"

    # 1. Удаляем кастомный конфиг доменов и обновляем dnsmasq
    if [ -f "/run/dnsmasq.conf.d/custom_vpn_bypass.conf" ]; then
        log_msg "INFO" "Удаление доменных конфигураций dnsmasq..."
        rm -f /run/dnsmasq.conf.d/custom_vpn_bypass.conf
        killall -HUP dnsmasq || killall dnsmasq || true
    fi

    # 2. Демонтируем ядерные правила ipset/iptables
    if [ -f "$BYPASS_MODULE" ]; then
        if [ -d "$BYPASS_PARTS_DIR" ]; then
            for part_file in "$BYPASS_PARTS_DIR"/*; do
                [ -e "$part_file" ] && /bin/bash "$BYPASS_MODULE" stop "$part_file" 2>/dev/null || true
            done
        fi

        if [ -f "$BYPASS_HOSTS_FILE" ]; then
            /bin/bash "$BYPASS_MODULE" stop "$BYPASS_HOSTS_FILE" 2>/dev/null || true
        fi
        
        /bin/bash "$BYPASS_MODULE" clean 2>/dev/null || true
    fi

    log_msg "INFO" "Очистка подсистемы обхода завершена."
}

# --- Логика обработки аргументов ---
case "$1" in
    start)
        load_bypass_logic
        ;;
    stop|clean)
        unload_bypass_logic
        ;;
    restart)
        unload_bypass_logic
        load_bypass_logic
        ;;
    *)
        echo "Usage: $0 {start|stop|clean|restart}"
        exit 1
        ;;
esac
