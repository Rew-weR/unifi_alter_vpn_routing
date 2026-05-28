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
