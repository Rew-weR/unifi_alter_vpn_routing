#!/usr/bin/env bash

# ==============================================================================
# CUSTOM VPN ROUTING SUITE FOR UNIFI OS (v2.8.8-Stable) - BYPASS CORE MODULE
# ==============================================================================

set -e

# --- Базовые пути и импорт конфигурации ---
CONF_FILE="/data/vpn-router/vpn-routing.conf"

if [ -f "$CONF_FILE" ]; then
    . "$CONF_FILE"
else
    echo "[CRITICAL] Configuration file $CONF_FILE not found in bypass module!"
    exit 1
fi

# Константы для маркировки пакетов (FWMARK)
FWMARK_ID="0x99"
PREF_BYPASS_RULE=1500

# Логирование
log_msg() {
    local level="$1"
    local message="$2"
    echo "[$level] $message"
    logger -t "$LOG_TAG" "[$level] (v2.8.8-CoreModule) $message"
}

# Проверка окружения (переданы ли параметры из лоадера/конфига)
if [ -z "$TARGET_PURE_TABLE_ID" ]; then
    # Быстрый фолбэк-детект, если запущен вне лоадера
    TARGET_PURE_TABLE_ID="178"
fi

# Функция генерации валидного имени ipset из пути к файлу
get_set_name() {
    local file_path="$1"
    local base_name
    base_name=$(basename "$file_path" | tr -cd 'a-zA-Z0-9_-')
    echo "vpn_${base_name:0:27}" # Ограничение длины имени ipset в ядре (31 символ)
}

# ==============================================================================
# РЕЖИМ ЗАПУСКА: ИНТЕГРАЦИЯ СПИСКА (START)
# ==============================================================================
start_bypass_file() {
    local file_in="$1"
    
    if [ ! -f "$file_in" ] || [ ! -s "$file_in" ]; then
        return 0
    fi

    local set_name
    set_name=$(get_set_name "$file_in")

    log_msg "INFO" "Инициализация ядра для списка: $set_name ($file_in)"

    # 1. Создаем ipset типа hash:net (поддерживает и одиночные IP, и подсети CIDR)
    if ! ipset list "$set_name" >/dev/null 2>&1; then
        # hashsize 4096, maxelem 65536 для оптимального потребления ОЗУ на UDM SE
        ipset create "$set_name" hash:net hashsize 4096 maxelem 65536
    fi

    # 2. Парсинг файла и атомарное наполнение ipset
    # Игнорируем комментарии (#) и пустые строки
    local added_count=0
    while IFS= read -r line || [ -n "$line" ]; do
        # Удаляем пробелы и комментарии
        line=$(echo "$line" | sed -e 's/#.*//' -e 's/[[:space:]]//g')
        [ -z "$line" ] && continue

        # Валидация: строка должна быть похожа на IP или подсеть
        if [[ "$line" =~ ^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}(/[0-9]{1,2})?$ ]]; then
            ipset add "$set_name" "$line" -exist >/dev/null 2>&1 || true
            ((added_count++))
        fi
    done < "$file_in"

    log_msg "INFO" "В список '$set_name' успешно загружено записей: $added_count"

    # 3. Настройка перехвата трафика через iptables PREROUTING (таблица mangle)
    # Маркируем пакеты, идущие к IP из нашего сета
    if ! iptables -t mangle -C PREROUTING -m set --match-set "$set_name" dst -j MARK --set-xmark "${FWMARK_ID}/0xffffffff" >/dev/null 2>&1; then
        iptables -t mangle -A PREROUTING -m set --match-set "$set_name" dst -j MARK --set-xmark "${FWMARK_ID}/0xffffffff"
    fi

    # 4. Добавляем системное правило маршрутизации для маркированного трафика (ip rule)
    # Strict IP Rule Syntax: используем table и pref вместо lookup/priority
    if ! ip rule list | grep -F "fwmark $FWMARK_ID pref $PREF_BYPASS_RULE table $TARGET_PURE_TABLE_ID" >/dev/null 2>&1; then
        ip rule add fwmark "$FWMARK_ID" pref "$PREF_BYPASS_RULE" table "$TARGET_PURE_TABLE_ID"
    fi
}

# ==============================================================================
# РЕЖИМ ДЕМОНТАЖА: ОЧИСТКА СПИСКА (STOP)
# ==============================================================================
stop_bypass_file() {
    local file_in="$1"
    if [ ! -f "$file_in" ]; then return 0; fi

    local set_name
    set_name=$(get_set_name "$file_in")

    log_msg "INFO" "Удаление правил ядра для списка: $set_name"

    # Удаляем правило маркировки из iptables
    iptables -t mangle -D PREROUTING -m set --match-set "$set_name" dst -j MARK --set-xmark "${FWMARK_ID}/0xffffffff" >/dev/null 2>&1 || true

    # Уничтожаем ipset
    ipset destroy "$set_name" >/dev/null 2>&1 || true
}

# ==============================================================================
# ГЛОБАЛЬНАЯ ТОТАЛЬНАЯ ЗАЧИСТКА (CLEAN)
# ==============================================================================
global_clean() {
    log_msg "INFO" "Запуск тотальной очистки подсистемы маркировки обхода..."

    # Удаляем системное правило маршрутизации по маркеру
    while ip rule del fwmark "$FWMARK_ID" pref "$PREF_BYPASS_RULE" table "$TARGET_PURE_TABLE_ID" 2>/dev/null; do :; done

    # Поиск и уничтожение всех динамических ipset с префиксом vpn_
    local active_sets
    active_sets=$(ipset list -n | grep "^vpn_" || true)

    for set in $active_sets; do
        iptables -t mangle -D PREROUTING -m set --match-set "$set" dst -j MARK --set-xmark "${FWMARK_ID}/0xffffffff" >/dev/null 2>&1 || true
        ipset destroy "$set" >/dev/null 2>&1 || true
    done
}

# --- Логика обработки аргументов ---
case "$1" in
    start)
        if [ -z "$2" ]; then
            echo "Error: Missing file path for start command"
            exit 1
        fi
        start_bypass_file "$2"
        ;;
    stop)
        if [ -z "$2" ]; then
            echo "Error: Missing file path for stop command"
            exit 1
        fi
        stop_bypass_file "$2"
        ;;
    clean)
        global_clean
        ;;
    *)
        echo "Usage: $0 {start <file_path>|stop <file_path>|clean}"
        exit 1
        ;;
esac
