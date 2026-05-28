#!/usr/bin/env bash

# ==============================================================================
# CUSTOM VPN ROUTING SUITE FOR UNIFI OS (v2.8.0-Stable) - INTERACTIVE INSTALLER
# ==============================================================================
# Разработано для архитектуры Ubiquiti UniFi OS (UDM SE, UDM Pro).
# Гарантирует персистентность конфигураций ядра Linux после обновлений прошивки.
# ==============================================================================

set -e # Останавливать выполнение при любой критической ошибке

# --- Глобальные пути и параметры ---
TOOL_PATH="/data/vpn-router"
LANG_DIR="${TOOL_PATH}/languages"
CONFIG_FILE="${TOOL_PATH}/vpn-routing.conf"
SERVICE_FILE="${TOOL_PATH}/custom-vpn-route.service"
SYSTEMD_DIR="/etc/systemd/system"

# Проверка прав суперпользователя
if [ "$EUID" -ne 0 ]; then
    echo "====================================================="
    echo "  [ERROR] Пожалуйста, запустите инсталлятор от root!"
    echo "====================================================="
    exit 1
fi

echo "====================================================="
echo "   ПОДГОТОВКА ОКРУЖЕНИЯ И ДИРЕКТОРИЙ UDM SE          "
echo "====================================================="
echo "Проверка базовой структуры каталогов..."

# Создаем структуру директорий приложения
mkdir -p "$TOOL_PATH"
mkdir -p "$LANG_DIR"
mkdir -p "${TOOL_PATH}/routes-backup"
mkdir -p "${TOOL_PATH}/bypass-parts"

# Нативная проверка и установка необходимых системных утилит, если они отсутствуют
if ! command -v ipset &> /dev/null || ! command -v curl &> /dev/null; then
    echo "Обновление пакетной базы и нативная установка системных утилит..."
    apt-get update -qy && apt-get install -qy ipset curl
fi

# ==============================================================================
# ДИНАМИЧЕСКАЯ ИНИЦИАЛИЗАЦИЯ ЯЗЫКОВЫХ ПАКЕТОВ (i18n)
# ==============================================================================
# Если папка локализации пуста, генерируем базовые словари по умолчанию
if [ -z "$(ls -A "$LANG_DIR" 2>/dev/null)" ]; then
    echo "Локализационные файлы отсутствуют. Генерация пакетов по умолчанию..."
    
    # Русский пакет локализации (ru.conf)
    cat << 'EOF' > "${LANG_DIR}/ru.conf"
MSG_WELCOME="Добро пожаловать в установщик Custom VPN Routing Suite!"
MSG_SELECT_LANG="Выберите язык интерфейса из списка доступных конфигураций:"
MSG_INVALID_CHOICE="Неверный выбор. Повторите попытку."
MSG_LOADING_CONFIG="Загрузка глобальной конфигурации системы..."
MSG_FIND_INTERFACE="Поиск ядерного имени для интерфейса GUI: "
MSG_PARSE_TABLE="Парсинг и валидация ID таблицы маршрутизации UniFi OS..."
MSG_SUCCESS_INSTALL="[SUCCESS] Установка успешно завершена! Модуль активирован."
MSG_CRON_SETUP="Интеграция отказоустойчивого Cron-триггера @reboot..."
MSG_SERVICE_INIT="Инициализация и запуск системной службы systemd..."
EOF

    # Английский пакет локализации (en.conf)
    cat << 'EOF' > "${LANG_DIR}/en.conf"
MSG_WELCOME="Welcome to the Custom VPN Routing Suite Installer!"
MSG_SELECT_LANG="Select your interface language from the available configurations:"
MSG_INVALID_CHOICE="Invalid choice. Please try again."
MSG_LOADING_CONFIG="Loading global system configuration..."
MSG_FIND_INTERFACE="Searching for kernel interface name mapped to GUI: "
MSG_PARSE_TABLE="Parsing and validating UniFi OS routing table ID..."
MSG_SUCCESS_INSTALL="[SUCCESS] Installation completed successfully! Suite is active."
MSG_CRON_SETUP="Injecting persistent Cron @reboot trigger..."
MSG_SERVICE_INIT="Initializing and starting systemd service profile..."
EOF
fi

# Сканируем папку languages/ на наличие файлов *.conf для динамического меню
echo "====================================================="
echo "   SELECT YOUR LANGUAGE / ВЫБЕРИТЕ ЯЗЫК ИНТЕРФЕЙСА  "
echo "====================================================="

AVAILABLE_LANGS=()
COUNTER=1

for lang_file in "${LANG_DIR}"/*.conf; do
    [ -e "$lang_file" ] || continue
    # Извлекаем чистое имя (ru, en, etc.)
    lang_code=$(basename "$lang_file" .conf)
    AVAILABLE_LANGS+=("$lang_code")
    
    # Красивый вывод для базовых языков
    if [ "$lang_code" == "ru" ]; then
        echo "${COUNTER} - Русский (${lang_code})"
    elif [ "$lang_code" == "en" ]; then
        echo "${COUNTER} - English (${lang_code})"
    else
        echo "${COUNTER} - ${lang_code}"
    fi
    ((COUNTER++))
done

while true; do
    read -p "Choice / Выбор [1-$((COUNTER-1))]: " LANG_CHOICE
    if [[ "$LANG_CHOICE" =~ ^[0-9]+$ ]] && [ "$LANG_CHOICE" -ge 1 ] && [ "$LANG_CHOICE" -lt "$COUNTER" ]; then
        UI_LANG="${AVAILABLE_LANGS[$((LANG_CHOICE-1))]}"
        break
    else
        echo "Invalid choice / Неверный выбор. Try again."
    fi
done

# ПРАВИЛЬНЫЙ, БЕЗОПАСНЫЙ ИМПОРТ ЯЗЫКОВОГО ПАКЕТА (Исправление строки 134)
. "${LANG_DIR}/${UI_LANG}.conf"

echo "-----------------------------------------------------"
echo "$MSG_WELCOME"
echo "-----------------------------------------------------"

# Проверяем наличие основного конфигурационного файла
if [ ! -f "$CONFIG_FILE" ]; then
    echo "[WARNING] Конфигурационный файл $CONFIG_FILE не найден. Создание стандартного шаблона..."
    
    cat << 'EOF' > "$CONFIG_FILE"
# Глобальные параметры VPN-маршрутизатора
SYSTEM_LANGUAGE="ru"
TARGET_WG_INTERFACE_GUI="WG-Zhmyak2"
EOF
    # Обновляем язык в новом файле конфигурации под выбор пользователя
    sed -i "s/SYSTEM_LANGUAGE=.*/SYSTEM_LANGUAGE=\"$UI_LANG\"/" "$CONFIG_FILE"
fi

# Подгружаем глобальную конфигурацию
echo "$MSG_LOADING_CONFIG"
. "$CONFIG_FILE"

# По умолчанию обновляем выбранный язык в конфиге
sed -i "s/SYSTEM_LANGUAGE=.*/SYSTEM_LANGUAGE=\"$UI_LANG\"/" "$CONFIG_FILE"

# ==============================================================================
# АНАЛИЗ И ОБХОД ОГРАНИЧЕНИЙ ЯДРА UNIFI OS
# ==============================================================================
echo "$MSG_FIND_INTERFACE ${TARGET_WG_INTERFACE_GUI}"

# Динамический поиск интерфейса wgcltX по его GUI-имени через встроенную утилиту уники или ip link
# В UniFi OS интерфейсы WireGuard клиента именуются как wgclt+номер
WG_KERNEL_IFace=$(ip link show | grep -oE "wgclt[0-9]+" | head -n 1)

if [ -z "$WG_KERNEL_IFace" ]; then
    echo "[WARNING] Активный WireGuard-интерфейс клиента не обнаружен в ядре."
    echo "Убедитесь, что туннель '${TARGET_WG_INTERFACE_GUI}' включен в панели UniFi Network."
    WG_KERNEL_IFace="wgclt4" # Фолбэк по умолчанию для предотвращения сбоя инсталляции
fi

echo "$MSG_PARSE_TABLE"
# Решение проблемы Table Splitting Bug:
# Получаем имя таблицы UniFi (например, 178.wgclt4) и строго отрезаем суффикс, оставляя только Integer ID
UNIFI_TABLE_RAW=$(ip route show table all | grep -m1 "$WG_KERNEL_IFace" | awk '{print $3}')

if [[ "$UNIFI_TABLE_RAW" == *"."* ]]; then
    # Строго отсекаем точку и строку через cut, исключая некорректный sed
    PURE_TABLE_ID=$(echo "$UNIFI_TABLE_RAW" | cut -d'.' -f1)
else
    PURE_TABLE_ID="178" # Фолбэк-константа, если уники еще не создали таблицу
fi

# Проверка на валидность ID таблицы (должно быть числом)
if ! [[ "$PURE_TABLE_ID" =~ ^[0-9]+$ ]]; then
    PURE_TABLE_ID="178"
fi

# ==============================================================================
# НАСТРОЙКА ПЕРСИСТЕНТНОСТИ SYSTEMD И CRON
# ==============================================================================
echo "$MSG_SERVICE_INIT"

# Если в репозитории лежал шаблон сервиса, проверяем его или создаем заново с явным Bash
cat << EOF > "$SERVICE_FILE"
[Unit]
Description=Custom VPN and DC Routing Configuration (v2.8.0-Stable)
After=network.target

[Service]
Type=idle
RemainAfterExit=yes
# Принудительный запуск через чистый bash для предотвращения сбоев оболочки dash (/bin/sh)
ExecStartPre=/bin/bash ${TOOL_PATH}/vpn-routing-control.sh clean
ExecStart=/bin/bash ${TOOL_PATH}/vpn-routing-control.sh start
ExecStop=/bin/bash ${TOOL_PATH}/vpn-routing-control.sh stop

[Install]
WantedBy=multi-user.target
EOF

# Делаем скрипты исполняемыми
chmod +x "${TOOL_PATH}"/*.sh 2>/dev/null || true
chmod +x ./install-vpn-router.sh

# Создаем символическую ссылку в системную директорию systemd
ln -sf "$SERVICE_FILE" "${SYSTEMD_DIR}/custom-vpn-route.service"

# Перезапускаем конфигурацию systemd и активируем службу
systemctl daemon-reload
systemctl enable custom-vpn-route.service

echo "$MSG_CRON_SETUP"
# Защита от затирания / при обновлении прошивки UniFi OS (Revenue Protection Logic)
# Механизм проверяет наличие symlink при каждой загрузке через Cron @reboot
CRON_JOB="@reboot [ ! -f ${SYSTEMD_DIR}/custom-vpn-route.service ] && ln -sf ${SERVICE_FILE} ${SYSTEMD_DIR}/custom-vpn-route.service && systemctl daemon-reload && systemctl start custom-vpn-route.service"

# Добавляем задачу в crontab root-пользователя, если её там еще нет
(crontab -l 2>/dev/null | grep -F "$SERVICE_FILE" && echo "Cron-триггер уже интегрирован.") || {
    (crontab -l 2>/dev/null; echo "$CRON_JOB") | crontab -
}

# Попытка первичного безопасного запуска службы
systemctl start custom-vpn-route.service || echo "[WARNING] Служба запустилась с предупреждением. Проверьте конфигурацию ядра."

echo "====================================================="
echo "$MSG_SUCCESS_INSTALL"
echo "====================================================="
