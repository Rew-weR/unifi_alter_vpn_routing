#!/usr/bin/env bash

# ==============================================================================
# CUSTOM VPN ROUTING SUITE FOR UNIFI OS (v2.8.5-Stable) - INTERACTIVE INSTALLER
# ==============================================================================

mkdir -p /data/vpn-router /data/vpn-router/languages /data/vpn-router/routes-backup /data/vpn-router/bypass-parts

set -e # Останавливать выполнение при любой критической ошибке

# --- Глобальные пути и параметры ---
TOOL_PATH="/data/vpn-router"
LANG_DIR="${TOOL_PATH}/languages"
CONFIG_FILE="${TOOL_PATH}/vpn-routing.conf"
SERVICE_FILE="${TOOL_PATH}/custom-vpn-route.service"
SYSTEMD_DIR="/etc/systemd/system"

# Проверка прав суперпользователя
if [ "$EUID" -ne 0 ]; then
    echo "[ERROR] Пожалуйста, запустите инсталлятор от root!"
    exit 1
fi

# Создаем структуру директорий приложения
mkdir -p "$TOOL_PATH"
mkdir -p "$LANG_DIR"
mkdir -p "${TOOL_PATH}/routes-backup"
mkdir -p "${TOOL_PATH}/bypass-parts"

# Проверка и установка утилит
if ! command -v ipset &> /dev/null || ! command -v curl &> /dev/null; then
    echo "Обновление пакетной базы и установка утилит..."
    apt-get update -qy && apt-get install -qy ipset curl
fi

# Генерируем языковые пакеты по умолчанию, если папка пуста
if [ -z "$(ls -A "$LANG_DIR" 2>/dev/null)" ]; then
    cat << 'EOF' > "${LANG_DIR}/ru.conf"
MSG_WELCOME="Добро пожаловать в интерактивный установщик Custom VPN Routing!"
MSG_SELECT_LANG="Выберите язык интерфейса / Select language:"
MSG_INVALID_CHOICE="Неверный выбор. Повторите попытку."
MSG_LOADING_CONFIG="Загрузка и генерация конфигурации системы..."
MSG_SUCCESS_INSTALL="[SUCCESS] Установка успешно завершена! Модуль активирован."
MSG_CRON_SETUP="Интеграция отказоустойчивого Cron-триггера @reboot..."
MSG_SERVICE_INIT="Инициализация и запуск системной службы systemd..."
MSG_ASK_WG_GUI="Введите имя WireGuard-клиента из интерфейса UniFi GUI (например, WG-Zhmyak2):"
MSG_ASK_IPSEC_GUI="Введите имя IPSec Site-to-Site из интерфейса UniFi GUI (например, CP-DC.IPSEC):"
MSG_DETECTED_IFACES="Обнаруженные активные VPN-интерфейсы в ядре:"
EOF

    cat << 'EOF' > "${LANG_DIR}/en.conf"
MSG_WELCOME="Welcome to the Interactive Custom VPN Routing Installer!"
MSG_SELECT_LANG="Select your interface language:"
MSG_INVALID_CHOICE="Invalid choice. Please try again."
MSG_LOADING_CONFIG="Loading and generating system configuration..."
MSG_SUCCESS_INSTALL="[SUCCESS] Installation completed successfully! Suite is active."
MSG_CRON_SETUP="Injecting persistent Cron @reboot trigger..."
MSG_SERVICE_INIT="Initializing and starting systemd service profile..."
MSG_ASK_WG_GUI="Enter WireGuard Client name from UniFi GUI (e.g., WG-Zhmyak2):"
MSG_ASK_IPSEC_GUI="Enter IPSec Site-to-Site name from UniFi GUI (e.g., CP-DC.IPSEC):"
MSG_DETECTED_IFACES="Detected active VPN interfaces in kernel:"
EOF
fi

# Динамическое меню выбора языка
echo "====================================================="
echo "   SELECT YOUR LANGUAGE / ВЫБЕРИТЕ ЯЗЫК ИНТЕРФЕЙСА  "
echo "====================================================="
AVAILABLE_LANGS=()
COUNTER=1
for lang_file in "${LANG_DIR}"/*.conf; do
    [ -e "$lang_file" ] || continue
    lang_code=$(basename "$lang_file" .conf)
    AVAILABLE_LANGS+=("$lang_code")
    [ "$lang_code" == "ru" ] && echo "${COUNTER} - Русский" || echo "${COUNTER} - ${lang_code}"
    ((COUNTER++))
done

while true; do
    read -p "Choice / Выбор [1-$((COUNTER-1))]: " LANG_CHOICE
    if [[ "$LANG_CHOICE" =~ ^[0-9]+$ ]] && [ "$LANG_CHOICE" -ge 1 ] && [ "$LANG_CHOICE" -lt "$COUNTER" ]; then
        UI_LANG="${AVAILABLE_LANGS[$((LANG_CHOICE-1))]}"
        break
    fi
done

. "${LANG_DIR}/${UI_LANG}.conf"

echo "-----------------------------------------------------"
echo "$MSG_WELCOME"
echo "-----------------------------------------------------"

# ==============================================================================
# ИНТЕРАКТИВНЫЙ ОПРОС ПОЛЬЗОВАТЕЛЯ ДЛЯ СБОРКИ vpn-routing.conf
# ==============================================================================
echo "=== НАСТРОЙКА КОНФИГУРАЦИИ МАРШРУТИЗАЦИИ ==="

# 1. Запрос имени WireGuard интерфейса в GUI
read -p "$MSG_ASK_WG_GUI " USER_WG_GUI
[ -z "$USER_WG_GUI" ] && USER_WG_GUI="WG-Zhmyak2"

# Автоматическое определение ядерного интерфейса для подсказки
DETECTED_WG=$(ip link show | grep -oE "wgclt[0-9]+" | head -n 1 || echo "wgclt4")
read -p "Ядро определило интерфейс как [$DETECTED_WG]. Нажмите Enter для подтверждения или введите вручную: " USER_WG_KERNEL
[ -z "$USER_WG_KERNEL" ] && USER_WG_KERNEL="$DETECTED_WG"

# Автоматическое определение ID таблицы для подсказки
UNIFI_TABLE_RAW=$(ip route show table all | grep -m1 "$USER_WG_KERNEL" | awk '{print $3}' || echo "178.wgclt")
PURE_TABLE_ID=$(echo "$UNIFI_TABLE_RAW" | cut -d'.' -f1)
if ! [[ "$PURE_TABLE_ID" =~ ^[0-9]+$ ]]; then PURE_TABLE_ID="178"; fi

read -p "Определен ID таблицы маршрутизации UniFi [$PURE_TABLE_ID]. Подтвердите или введите вручную: " USER_TABLE_ID
[ -z "$USER_TABLE_ID" ] && USER_TABLE_ID="$PURE_TABLE_ID"

# Получение IP адреса WireGuard интерфейса
DETECTED_IP=$(ip addr show "$USER_WG_KERNEL" 2>/dev/null | grep -oE 'inet [0-9.]+' | awk '{print $2}' || echo "10.151.0.3")
read -p "Определен статический IP туннеля [$DETECTED_IP]. Подтвердите или введите вручную: " USER_WG_IP
[ -z "$USER_WG_IP" ] && USER_WG_IP="$DETECTED_IP"

# 2. Запрос имени IPSec туннеля в GUI
read -p "$MSG_ASK_IPSEC_GUI " USER_IPSEC_GUI
[ -z "$USER_IPSEC_GUI" ] && USER_IPSEC_GUI="CP-DC.IPSEC"

echo "-----------------------------------------------------"
echo "Вывод текущих активных интерфейсов для подсказки:"
ip -br link show | grep -E 'wgsrv|tun|l2tp|ppp' || echo "Входящие VPN-сервера сейчас не активны."
echo "-----------------------------------------------------"

# Генерируем финальный чистый vpn-routing.conf на основе ответов
cat << EOF > "$CONFIG_FILE"
# ==============================================================================
# CUSTOM VPN ROUTING SUITE FOR UNIFI OS - GENERATED CONFIGURATION
# ==============================================================================
SYSTEM_LANGUAGE="${UI_LANG}"
TOOL_PATH="${TOOL_PATH}"
LOG_TAG="CustomVPNRouting"
BACKUP_DIR="${TOOL_PATH}/routes-backup"
MAX_BACKUPS=10

# --- Outbound Targets & Destinations ---
TARGET_WG_INTERFACE_GUI="${USER_WG_GUI}"
TARGET_WG_KERNEL="${USER_WG_KERNEL}"
TARGET_WG_STATIC_IP="${USER_WG_IP}"
TARGET_PURE_TABLE_ID="${USER_TABLE_ID}"

TARGET_IPSEC_INTERFACE_GUI="${USER_IPSEC_GUI}"

# --- Inbound Client VPN Networks (Sources) ---
# Настройки подсетей из ТЗ (можно менять вручную в конфигурационном файле)
SRC_NETWORKS=(
    "wgsrv1:192.168.6.0/24:PBR_AND_DC"     # WG.WORK
    "tun1:192.168.5.0/24:PBR_AND_DC"      # OVPN.WORK
    "wgsrv3:10.11.12.0/24:PBR_ONLY"       # WG.CLIENTS
    "wgsrv5:192.168.10.0/24:PBR_AND_DC"   # CYPE.MOBILE
    "l2tp0:192.168.3.0/24:PBR_ONLY"       # L2TP.WORK
)

# --- Datacenter Remote Subnets ---
DC_REMOTE_SUBNETS=(
    "172.20.150.0/22"
    "172.20.154.0/24"
    "172.20.155.0/24"
)

# --- Local Networks Isolation ---
LOCAL_SUPERNETS=(
    "172.20.0.0/16"
    "192.168.0.0/16"
)

# --- Routing Priorities (Preferences) ---
PREF_LOCAL_ISOLATION=1000
PREF_IPSEC_INTERCEPT=10500
PREF_VPN_PBR_BASE=2000

# --- Telemetry & Watchdog ---
CHECK_HOSTS=("1.1.1.1" "9.9.9.9" "8.8.8.8")
PING_INTERVAL_MINUTES=5
TELEGRAM_BOT_TOKEN=""
TELEGRAM_CHAT_ID=""

BYPASS_HOSTS_FILE="${TOOL_PATH}/bypass-hosts.list"
BYPASS_PARTS_DIR="${TOOL_PATH}/bypass-parts"
EOF

echo "Конфигурационный файл успешно сгенерирован в $CONFIG_FILE"

# ==============================================================================
# НАСТРОЙКА ПЕРСИСТЕНТНОСТИ SYSTEMD И CRON
# ==============================================================================
echo "$MSG_SERVICE_INIT"

cat << EOF > "$SERVICE_FILE"
[Unit]
Description=Custom VPN and DC Routing Configuration (v2.8.5-Stable)
After=network.target

[Service]
Type=idle
RemainAfterExit=yes
ExecStartPre=/bin/bash ${TOOL_PATH}/vpn-routing-control.sh clean
ExecStart=/bin/bash ${TOOL_PATH}/vpn-routing-control.sh start
ExecStop=/bin/bash ${TOOL_PATH}/vpn-routing-control.sh stop

[Install]
WantedBy=multi-user.target
EOF

# Права доступа
chmod +x "${TOOL_PATH}"/*.sh 2>/dev/null || true
chmod +x ./install-vpn-router.sh

# Симлинк для службы
ln -sf "$SERVICE_FILE" "${SYSTEMD_DIR}/custom-vpn-route.service"
systemctl daemon-reload
systemctl enable custom-vpn-route.service

echo "$MSG_CRON_SETUP"
CRON_JOB="@reboot [ ! -f ${SYSTEMD_DIR}/custom-vpn-route.service ] && ln -sf ${SERVICE_FILE} ${SYSTEMD_DIR}/custom-vpn-route.service && systemctl daemon-reload && systemctl start custom-vpn-route.service"
(crontab -l 2>/dev/null | grep -F "$SERVICE_FILE" && echo "Cron-триггер уже интегрирован.") || {
    (crontab -l 2>/dev/null; echo "$CRON_JOB") | crontab -
}

# Запуск службы
systemctl start custom-vpn-route.service || echo "[WARNING] Служба инициализирована, проверьте правила маршрутизации ядра."

echo "====================================================="
echo "$MSG_SUCCESS_INSTALL"
echo "====================================================="
