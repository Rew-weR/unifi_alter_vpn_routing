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
    # ИНТЕЛЛЕКТУАЛЬНЫЙ СУПЕР-ВЫБОР КАНАЛА ДЛЯ СКАЧИВАНИЯ СПИСКОВ
    # --------------------------------------------------------------------------
    if [ -n "$BYPASS_REMOTE_URL" ]; then
        # 1. Извлекаем домен/хост из URL для проверки пинга/доступности
        local remote_host
        remote_host=$(echo "$BYPASS_REMOTE_URL" | awk -F[/:] '{print $4}')
        
        # 2. Определяем имя физического WAN1
        local wan1_interface
        wan1_interface=$(ip route show table all | grep "proto DefaultGateway" | grep -oE "dev [a-zA-Z0-9.-]+" | awk '{print $2}' | head -n 1 || true)
        [ -z "$wan1_interface" ] && wan1_interface="eth8"

        # Очищаем имя интерфейса туннеля
        local vpn_interface="${TARGET_WG_KERNEL:-wgclt4}"

        log_msg "INFO" "Проверка доступности узла $remote_host..."
        
        # Переменная для финального выбора интерфейса скачивания
        local selected_interface=""

        # Тестируем обычный интернет провайдера (WAN1)
        if curl --interface "$wan1_interface" -sI --max-time 3 "$BYPASS_REMOTE_URL" >/dev/null 2>&1; then
            log_msg "INFO" "Узел доступен через обычный канал связи. Выбран WAN1 ($wan1_interface)."
            selected_interface="$wan1_interface"
        # Тестируем защищенный канал (VPN)
        elif curl --interface "$vpn_interface" -sI --max-time 3 "$BYPASS_REMOTE_URL" >/dev/null 2>&1; then
            log_msg "WARNING" "Узел заблокирован или недоступен через WAN1! Обнаружен доступ через туннель. Выбран VPN ($vpn_interface)."
            selected_interface="$vpn_interface"
        else
            log_msg "ERROR" "Узел полностью недоступен через все каналы связи (WAN1 и VPN)."
        fi

        # Выполняем скачивание через успешно протестированный интерфейс
        if [ -n "$selected_interface" ]; then
            log_msg "INFO" "Запуск скачивания списка через интерфейс: $selected_interface"
            if curl --interface "$selected_interface" -sSL "$BYPASS_REMOTE_URL" -o "$BYPASS_HOSTS_FILE" --max-time 25; then
                log_msg "INFO" "Глобальный файл списков адресов успешно обновлен."
            else
                log_msg "ERROR" "Сбой curl при скачивании файла через $selected_interface."
            fi
        else
            log_msg "WARNING" "Скачивание невозможно. Будет использована старая локальная копия файла (при наличии)."
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
esac
