#!/usr/bin/env bash

# ==============================================================================
# CUSTOM VPN ROUTING SUITE FOR UNIFI OS (v2.8.7-Stable) - BYPASS LOADER
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

# Подгружаем языковой пакет для вывода логов
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
    logger -t "$LOG_TAG" "[$level] (v2.8.7-Bypass) $message"
}

# Скрипт-исполнитель логики обхода
BYPASS_MODULE="${TOOL_PATH}/vpn-bypass-module.sh"

# ==============================================================================
# ЗАПУСК ИНИЦИАЛИЗАЦИИ СПИСКОВ (START)
# ==============================================================================
load_bypass_logic() {
    log_msg "INFO" "${MSG_STARTING_BYPASS:-Инициализация подсистемы обхода блокировок...}"

    if [ ! -f "$BYPASS_MODULE" ]; then
        log_msg "ERROR" "Исполняемый модуль $BYPASS_MODULE не найден. Обход отключен."
        exit 1
    fi

    # Гарантируем, что модуль имеет права на запуск
    chmod +x "$BYPASS_MODULE"

    # Экспортируем ID таблицы WireGuard, чтобы модуль гарантированно знал куда рулить трафик
    # Если переменная пуста в конфиге, делаем быстрый динамический детект
    if [ -z "$TARGET_PURE_TABLE_ID" ]; then
        local detected_iface
        detected_iface=$(ip -br link show | grep -oE "wgclt[0-9]+" | head -n 1 || echo "wgclt4")
        local unifi_table_raw
        unifi_table_raw=$(ip route show table all | grep -m1 "$detected_iface" | awk '{print $3}' || echo "178")
        TARGET_PURE_TABLE_ID=$(echo "$unifi_table_raw" | cut -d'.' -f1)
    fi
    export TARGET_PURE_TABLE_ID
    export TARGET_WG_KERNEL

    # 1. Обработка атомарных сегментов / списков IP/Доменов в bypass-parts/
    if [ -d "$BYPASS_PARTS_DIR" ] && [ "$(ls -A "$BYPASS_PARTS_DIR" 2>/dev/null)" ]; then
        log_msg "INFO" "Обнаружены кастомные сегменты в $BYPASS_PARTS_DIR. Запуск пакетной обработки..."
        
        for part_file in "$BYPASS_PARTS_DIR"/*; do
            [ -e "$part_file" ] || continue
            local part_name
            part_name=$(basename "$part_file")
            
            log_msg "INFO" "Обработка сегмента обхода: $part_name"
            /bin/bash "$BYPASS_MODULE" start "$part_file" || log_msg "WARNING" "Ошибка обработки сегмента $part_name"
        done
    else
        log_msg "INFO" "Директория сегментов обхода $BYPASS_PARTS_DIR пуста."
    fi

    # 2. Обработка глобального файла хостов bypass-hosts.list (если он существует)
    if [ -f "$BYPASS_HOSTS_FILE" ] && [ -s "$BYPASS_HOSTS_FILE" ]; then
        log_msg "INFO" "Обнаружен глобальный список хостов $BYPASS_HOSTS_FILE. Запуск интеграции..."
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
        # Передаем команду stop во все файлы сегментов для чистого удаления ipset/nftables
        if [ -d "$BYPASS_PARTS_DIR" ]; then
            for part_file in "$BYPASS_PARTS_DIR"/*; do
                [ -e "$part_file" ] || continue
                /bin/bash "$BYPASS_MODULE" stop "$part_file" 2>/dev/null || true
            done
        fi

        if [ -f "$BYPASS_HOSTS_FILE" ]; then
            /bin/bash "$BYPASS_MODULE" stop "$BYPASS_HOSTS_FILE" 2>/dev/null || true
        fi
        
        # Финальный вызов модуля без параметров для глобальной зачистки зависших таблиц
        /bin/bash "$BYPASS_MODULE" clean 2>/dev/null || true
    fi

    log_msg "INFO" "Очистка подсистемы обхода завершена."
}

# --- Обработка аргументов ---
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
