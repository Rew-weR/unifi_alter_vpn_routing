#!/usr/bin/env bash

# ==============================================================================
# CUSTOM VPN ROUTING SUITE FOR UNIFI OS (v2.9.5-Stable) - BYPASS LOADER
# ==============================================================================
# Модуль интеллектуальной загрузки, проверки каналов и парсинга списков обхода.
# Гарантирует автономность, i18n-совместимость и автоматическую адаптацию к ядру.
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
    # Резервные строки на случай отсутствия языкового пакета
    MSG_STARTING_BYPASS="Инициализация списков обхода..."
    MSG_STOPPING_BYPASS="Очистка списков обхода..."
fi

# Единый фреймворк логирования (syslog + stdout)
log_msg() {
    local level="$1"
    local message="$2"
    echo "[$level] $message"
    logger -t "$LOG_TAG" "[$level] (v2.9.5-Loader) $message"
}

# Скрипт-исполнитель логики обхода (Core Module)
BYPASS_MODULE="${TOOL_PATH}/vpn-bypass-module.sh"

# ==============================================================================
# ЗАПУСК ИНИЦИАЛИЗАЦИИ, ПРОВЕРКИ И СКАЧИВАНИЯ (START)
# ==============================================================================
load_bypass_logic() {
    log_msg "INFO" "${MSG_STARTING_BYPASS:-Инициализация подсистемы обхода блокировок...}"

    if [ ! -f "$BYPASS_MODULE" ]; then
        log_msg "ERROR" "Исполняемый модуль $BYPASS_MODULE не найден. Обход отключен."
        exit 1
    fi

    # Гарантируем права на выполнение основного модуля
    chmod +x "$BYPASS_MODULE"

    # --------------------------------------------------------------------------
    # ДИНАМИЧЕСКИЙ ДЕТЕКТ ИНТЕРФЕЙСА И ID ТАБЛИЦЫ ИЗ АКТИВНОГО ЯДРА UNIFI
    # --------------------------------------------------------------------------
    # Сканируем таблицы UniFi для поиска связки вида 178.wgcltX (динамическая защита)
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

    # Фолбэки, если таблицы ядра еще не успели инициализироваться
    if [ -z "$detected_kernel_iface" ]; then
        detected_kernel_iface=$(ip -br link show | grep -oE "wgclt[0-9]+" | head -n 1 || echo "wgclt4")
    fi
    if [ -z "$detected_table_id" ]; then
        detected_table_id="178"
    fi

    # Экспортируем строго выверенные переменные для дочернего vpn-bypass-module.sh
    TARGET_WG_KERNEL="$detected_kernel_iface"
    TARGET_PURE_TABLE_ID="$detected_table_id"
    
    export TARGET_WG_KERNEL
    export TARGET_PURE_TABLE_ID

    # --------------------------------------------------------------------------
    # ПРИОРИТЕТНАЯ ПРОВЕРКА РУЧНОГО ФАЙЛА И УМНОЕ СКАЧИВАНИЕ С ВЫБОРОМ КАНАЛА
    # --------------------------------------------------------------------------
    local need_download=true

    # 1. Проверяем локальный ручной файл ipsmart.lst
    if [ -n "$BYPASS_MANUAL_FILE" ] && [ -f "$BYPASS_MANUAL_FILE" ] && [ -s "$BYPASS_MANUAL_FILE" ]; then
        log_msg "INFO" "Обнаружен ручной файл списков: $BYPASS_MANUAL_FILE. Использование локальной копии."
        cp "$BYPASS_MANUAL_FILE" "$BYPASS_HOSTS_FILE"
        need_download=false
    fi

    # 2. Если ручного файла нет, запускаем двухэтапное скачивание по сети
    if [ "$need_download" = true ]; then
        if [ -n "$BYPASS_REMOTE_URL" ]; then
            local remote_host
            remote_host=$(echo "$BYPASS_REMOTE_URL" | awk -F[/:] '{print $4}')
            
            # Находим нативный физический интерфейс WAN1
            local wan1_interface
            wan1_interface=$(ip route show table all | grep "proto DefaultGateway" | grep -oE "dev [a-zA-Z0-9.-]+" | awk '{print $2}' | head -n 1 || true)
            [ -z "$wan1_interface" ] && wan1_interface="eth8"

            local vpn_interface="$TARGET_WG_KERNEL"
            local selected_interface=""

            log_msg "INFO" "Локальный файл не найден. Проверка доступности узла $remote_host..."
            
            # Тест 1: Проверяем обычный интернет провайдера (WAN1)
            if curl --interface "$wan1_interface" -sI --max-time 3 "$BYPASS_REMOTE_URL" >/dev/null 2>&1; then
                log_msg "INFO" "Узел доступен напрямую. Для скачивания выбран WAN1 ($wan1_interface)."
                selected_interface="$wan1_interface"
            # Тест 2: Если заблокировано, проверяем защищенный туннель (VPN)
            elif curl --interface "$vpn_interface" -sI --max-time 3 "$BYPASS_REMOTE_URL" >/dev/null 2>&1; then
                log_msg "WARNING" "Узел недоступен через WAN1! Обнаружен доступ через туннель. Выбран VPN ($vpn_interface)."
                selected_interface="$vpn_interface"
            else
                log_msg "ERROR" "Узел полностью недоступен через все каналы связи (WAN1 и VPN)."
            fi

            # Выполняем скачивание через успешно протестированный интерфейс
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

    # 1. Пакетная обработка кастомных сегментов в директории bypass-parts/
    if [ -d "$BYPASS_PARTS_DIR" ] && [ "$(ls -A "$BYPASS_PARTS_DIR" 2>/dev/null)" ]; then
        log_msg "INFO" "Обнаружены кастомные сегменты в $BYPASS_PARTS_DIR. Запуск пакетной обработки..."
        
        for part_file in "$BYPASS_PARTS_DIR"/*; do
            [ -e "$part_file" ] || continue
            local part_name
            part_name=$(basename "$part_file")
            
            log_msg "INFO" "Обработка сегмента обхода: $part_name"
            /bin/bash "$BYPASS_MODULE" start "$part_file" || log_msg "WARNING" "Ошибка обработки сегмента $part_name"
        done
    fi

    # 2. Передача итогового файла хостов в ядерный модуль ipset
    if [ -f "$BYPASS_HOSTS_FILE" ] && [ -s "$BYPASS_HOSTS_FILE" ]; then
        log_msg "INFO" "Интеграция глобального списка хостов в таблицы ядра Linux..."
        /bin/bash "$BYPASS_MODULE" start "$BYPASS_HOSTS_FILE" || log_msg "WARNING" "Ошибка обработки глобального списка хостов."
    fi

    log_msg "INFO" "Подсистема обхода блокировок успешно развернута в ядре."
}

# ==============================================================================
# ДЕМОНТАЖ И ОЧИСТКА СПИСКОВ (STOP)
# ==============================================================================
unload_bypass_logic() {
    log_msg "INFO" "${MSG_STOPPING_BYPASS:-Демонтаж и полная очистка правил обхода блокировок...}"

    if [ -f "$BYPASS_MODULE" ]; then
        # Каскадно вычищаем правила для каждого сегмента в bypass-parts
        if [ -d "$BYPASS_PARTS_DIR" ]; then
            for part_file in "$BYPASS_PARTS_DIR"/*; do
                [ -e "$part_file" ] && /bin/bash "$BYPASS_MODULE" stop "$part_file" 2>/dev/null || true
            done
        fi

        # Вычищаем глобальный файл хостов
        if [ -f "$BYPASS_HOSTS_FILE" ]; then
            /bin/bash "$BYPASS_MODULE" stop "$BYPASS_HOSTS_FILE" 2>/dev/null || true
        fi
        
        # Финальный вызов глобальной очистки ipset таблиц
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
