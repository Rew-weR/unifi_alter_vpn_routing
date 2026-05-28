#!/usr/bin/env bash

# ==============================================================================
# CUSTOM VPN ROUTING SUITE FOR UNIFI OS (v2.9.1-Stable) - BYPASS LOADER
# ==============================================================================
# Модуль автоматической загрузки и парсинга списков обхода блокировок.
# Гарантирует скачивание файлов через нативный интерфейс WAN1.
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
    logger -t "$LOG_TAG" "[$level] (v2.9.1-Loader) $message"
}

# Скрипт-исполнитель логики обхода (Core Module)
BYPASS_MODULE="${TOOL_PATH}/vpn-bypass-module.sh"

# ==============================================================================
# ЗАПУСК ИНИЦИАЛИЗАЦИИ И СКАЧИВАНИЯ (START)
# ==============================================================================
load_bypass_logic() {
    log_msg "INFO" "${MSG_STARTING_BYPASS:-Инициализация подсистемы обхода блокировок...}"

    if [ ! -f "$BYPASS_MODULE" ]; then
        log_msg "ERROR" "Исполняемый модуль $BYPASS_MODULE не найден. Обход отключен."
        exit 1
    fi

    # Гарантируем права на выполнение основного модуля
    chmod +x "$BYPASS_MODULE"

    # Сквозной экспорт ID таблицы WireGuard туннеля для дочерних процессов
    if [ -z "$TARGET_PURE_TABLE_ID" ]; then
        local detected_iface
        detected_iface=$(ip -br link show | grep -oE "wgclt[0-9]+" | head -n 1 || echo "wgclt4")
        local unifi_table_raw
        unifi_table_raw=$(ip route show table all | grep -m1 "$detected_iface" | awk '{print $3}' || echo "178")
        TARGET_PURE_TABLE_ID=$(echo "$unifi_table_raw" | cut -d'.' -f1)
    fi
    export TARGET_PURE_TABLE_ID
    export TARGET_WG_KERNEL

    # --------------------------------------------------------------------------
    # НАДЕЖНОЕ АВТООПРЕДЕЛЕНИЕ ФИЗИЧЕСКОГО ИНТЕРФЕЙСА WAN1 И СКАЧИВАНИЕ
    # --------------------------------------------------------------------------
    if [ -n "$BYPASS_REMOTE_URL" ]; then
        # Парсим скрытые таблицы UniFi OS, ориентируясь на метку DefaultGateway
        local wan1_interface
        wan1_interface=$(ip route show table all | grep "proto DefaultGateway" | grep -oE "dev [a-zA-Z0-9.-]+" | awk '{print $2}' | head -n 1 || true)

        # Жесткий фолбэк на eth8, если магия UniFi не вернула интерфейс
        if [ -z "$wan1_interface" ]; then
            wan1_interface="eth8"
        fi

        log_msg "INFO" "Загрузка удаленного списка принудительно направлена через WAN1: $wan1_interface"
        log_msg "INFO" "Адрес источника: $BYPASS_REMOTE_URL"

        # Скачивание файла списков с ограничением времени cURL в 20 секунд
        if curl --interface "$wan1_interface" -sSL "$BYPASS_REMOTE_URL" -o "$BYPASS_HOSTS_FILE" --max-time 20; then
            log_msg "INFO" "Глобальный файл списков адресов успешно скачан и сохранен в $BYPASS_HOSTS_FILE"
        else
            log_msg "WARNING" "Не удалось обновить файл списков по сети через $wan1_interface. Будет использована локальная копия (при наличии)."
        fi
    else
        log_msg "WARNING" "Переменная BYPASS_REMOTE_URL не задана в vpn-routing.conf. Скачивание пропущено."
    fi
    # --------------------------------------------------------------------------

    # 1. Обработка кастомных сегментов в директории bypass-parts/
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

    # 2. Передача скачанного файла хостов в ядерный модуль ipset
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
case
