#!/bin/sh

# ===================================================================
# LOADER VERSION: v1.1.0-Stable (Safe Split & Restore)
# DESCRIPTION: Автоматическое скачивание, валидация и нарезка списков
# ===================================================================

SOURCE_URL="https://antifilter.network/download/ipsmart.lst" # Укажите ваш URL
PROJECT_DIR="/data/vpn-router"
BYPASS_DIR="$PROJECT_DIR/bypass-parts"
TEMP_FILE="/tmp/raw_subnets.txt"
CLEAN_FILE="/tmp/clean_subnets.txt"
SET_NAME="bypass_list"

# Подгружаем глобальные флаги
[ -f "$PROJECT_DIR/vpn-routing.conf" ] && . "$PROJECT_DIR/vpn-routing.conf"
[ "$ENABLE_BYPASS_MODULE" != "true" ] && exit 0

logger -t "VPNBypassLoader" "[INFO] Запуск обновления базы данных исключений..."

# 1. Скачивание свежего списка
curl -sL "$SOURCE_URL" -o "$TEMP_FILE"
if [ ! -s "$TEMP_FILE" ]; then
    logger -t "VPNBypassLoader" "[ERROR] Не удалось скачать файл или источник пуст."
    exit 1
fi

# 2. Глубокая очистка: убираем комментарии, пустые строки и проверяем валидность CIDR-структуры
grep -v '^#' "$TEMP_FILE" | grep -v '^$' | grep -E '^[0-9./]+$' | sort -u > "$CLEAN_FILE"

# 3. Безопасная порционная нарезка с суффиксами (защита от дублирования .txt.txt)
rm -rf "$BYPASS_DIR" && mkdir -p "$BYPASS_DIR"
# Флаг -d использует цифры (part_01, part_02), флаг --additional-suffix жестко фиксирует расширение
split -l 1000 -d --additional-suffix=.txt "$CLEAN_FILE" "$BYPASS_DIR/part_"

# 4. Мгновенная атомарная синхронизация со стеком ядра UDM SE
if ipset list "$SET_NAME" >/dev/null 2>&1; then
    (
        echo "flush $SET_NAME"
        while IFS= read -r subnet || [ -n "$subnet" ]; do
            echo "add $SET_NAME $subnet"
         Papka
        done < "$CLEAN_FILE"
    ) | ipset restore >/dev/null 2>&1
fi

# Удаляем временные файлы из /tmp/
rm -f "$TEMP_FILE" "$CLEAN_FILE"
logger -t "VPNBypassLoader" "[INFO] База данных IPSet успешно обновлена и нарезана на порции."

