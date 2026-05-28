#!/bin/sh

# ===================================================================
# INSTALLER VERSION: v2.7.3-Stable (Safe Enterprise Deployment)
# TOOL PATH: /data/vpn-router
# TARGET OS: UniFi OS 5.x (Debian-based)
# ===================================================================

ROUTING_TOOL_PATH="/data/vpn-router"
LANG_DIR="\$ROUTING_TOOL_PATH/languages"
CONFIG_FILE="\$ROUTING_TOOL_PATH/vpn-routing.conf"
CONTROL_SCRIPT="\$ROUTING_TOOL_PATH/vpn-routing-control.sh"
WATCHDOG_FILE="\$ROUTING_TOOL_PATH/vpn-watchdog.sh"
BYPASS_LOADER="\$ROUTING_TOOL_PATH/vpn-bypass-loader.sh"
UNINSTALL_SCRIPT="\$ROUTING_TOOL_PATH/uninstall-vpn-router.sh"
BYPASS_LIST="\$ROUTING_TOOL_PATH/bypass-hosts.list"

echo "====================================================="
echo "   ПОДГОТОВКА ОКРУЖЕНИЯ И ДИРЕКТОРИЙ UDM SE          "
echo "====================================================="

# 1. Безопасное создание изолированной структуры папок
mkdir -p "\$LANG_DIR" "\(ROUTING_TOOL_PATH/bypass-parts" "\)ROUTING_TOOL_PATH/routes-backup" /data/systemd

# 2. Нативная, чистая установка утилит без лишних зависимостей
echo "Обновление пакетной базы и нативная установка системных утилит..."
apt-get update -y >/dev/null 2>&1
apt-get install -y --no-install-recommends mc ipset nano wget curl >/dev/null 2>&1

echo "====================================================="
echo "   SELECT YOUR LANGUAGE / ВЫБЕРИТЕ ЯЗЫК ИНТЕРФЕЙСА  "
echo "====================================================="
echo "1 - English"
echo "2 - Русский"
printf "Choice / Выбор: "
read -r LANG_CHOICE

if [ "\$LANG_CHOICE" = "2" ]; then UI_LANG="ru"; else UI_LANG="en"; fi

# Инициализация встроенных языковых пакетов (i18n), если папка пуста
if [ ! -f "\(LANG_DIR/\){UI_LANG}.conf" ]; then
    echo "Инициализация локализации..."
    
    # Генерация ru.conf
    cat << 'EOF' > "\$LANG_DIR/ru.conf"
TEXT_BANNER="   ИНСТАЛЛЯТОР КАСТОМНОЙ МАРШРУТИЗАЦИИ ДЛЯ UDM SE   "
TEXT_ASK_WG="Введите точное имя WireGuard-клиента в GUI UniFi [WG-Zhmyak2]: "
TEXT_SCAN="Сканирование сетевого стека ядра для поиска IP-адреса туннеля..."
TEXT_DET_IP="Автоматически обнаружен активный IP-адрес туннеля: "
TEXT_CONF_IP="Использовать этот IP? (y/n) [y]: "
TEXT_MAN_IP="Введите внутренний IP-адрес этого VPN вручную: "
TEXT_ERR_IP="Предупреждение: Автоматически определить IP-адрес туннеля не удалось."
TEXT_ASK_BYPASS="Включить комбинированный модуль высокоскоростных исключений IPSet? (y/n) [n]: "
TEXT_ASK_DC="Есть необходимость маршрутизации впн клиентов в дополнительные туннели IPSec? (y/n) [n]: "
TEXT_NAME_DC="Введите точное имя IPSec туннеля до ДЦ в GUI UniFi [CP-DC.IPSEC]: "
TEXT_ASK_TG="Включить модуль Telegram-уведомлений? (y/n) [n]: "
TEXT_TG_TOKEN="Введите ваш Telegram Bot Token: "
TEXT_TG_CHAT="Введите ваш Telegram Chat ID: "
TEXT_ASK_WD="Включить фоновый модуль Watchdog (контроль связи)? (y/n) [n]: "
TEXT_WD_INT="Введите интервал проверки связи в минутах (от 1 до 59): "
TEXT_WD_WARN="Предупреждение: Некорректный интервал. Установлено значение: 5 минут."
TEXT_DONE="Установка успешно завершена! Модуль готов к работе."
MSG_ERR_PARAMS="Параметры Интернет-VPN не найдены в ядре. Отмена."
MSG_ERR_TG="❌ Ошибка запуска. Интерфейс \$EXIT_NODE_VPN_NAME не активен."
MSG_ERR_PING="Интернет через интерфейс недоступен. Блокировка."
MSG_ERR_PING_TG="⚠️ Внимание! Интернет в туннеле \$EXIT_NODE_VPN_NAME недоступен. Накат правил заблокирован."
MSG_START="=== НАЧАЛО СИНХРОНИЗАЦИИ МАРШРУТОВ ==="
MSG_DC_ON="Модуль ДЦ активен. Туннель ДЦ: \$DC_IPSEC_TUNNEL_NAME"
MSG_DC_OFF="Модуль интеграции с Дата-Центром ОТКЛЮЧЕН пользователем."
MSG_SUCCESS="Все кастомные политики мрашрутизации успешно добавлены и активированы."
MSG_SUCCESS_TG="✅ Кастомная маршрутизация успешно запущена. Выход в интернет через \$EXIT_NODE_VPN_NAME."
MSG_PING_TEST="Тестирование интернет-соединения через туннель"
TEXT_UP="Интернет в туннеле \$EXIT_NODE_VPN_NAME восстановился. Активация маршрутов."
TEXT_DOWN="Потеряна связь через туннель \$EXIT_NODE_VPN_NAME! Отключение правил."
TEXT_TG_DOWN="🚨 UDM SE Watchdog: Потеряна связь через туннель \(EXIT_NODE_VPN_NAME! Правила маршрутизации временно отключены для сохранения связи. Мониторинг: раз в \)WATCHDOG_INTERVAL_MINUTES мин."
TEXT_CONFIRM="Вы уверены, что хотите полностью удалить модуль? (y/n): "
TEXT_CANCEL="Отмена деинсталляции."
TEXT_UNINST="Остановка и отключение системной службы systemd..."
TEXT_CRON="Удаление триггеров автозапуска и Watchdog из Cron..."
TEXT_KERNEL="Полная очистка активных таблиц ядра маршрутизации и IPSet..."
TEXT_FILES="Удаление файлов и каталогов проекта..."
TEXT_SUCCESS="Деинсталляция успешно завершена! Система возвращена к заводским настройкам."
MSG_BYPASS_ON="Модуль исключений (Bypass IPSet) активен. Загрузка кэш-таблиц..."
MSG_BYPASS_OFF="Модуль высокоскоростных исключений IPSet отключен."
MSG_BYPASS_CLEAN="Правила модуля исключений IPSet очищены."
EOF

    # Генерация en.conf
    cat << 'EOF' > "\$LANG_DIR/en.conf"
TEXT_BANNER="   CUSTOM ROUTING INSTALLER FOR UNIFI DREAM MACHINE   "
TEXT_ASK_WG="Enter exact WireGuard Client Name from UniFi GUI [WG-Zhmyak2]: "
TEXT_SCAN="Scanning kernel network stack to find tunnel IP address..."
TEXT_DET_IP="Automatically detected active tunnel IP address: "
TEXT_CONF_IP="Use this IP address? (y/n) [y]: "
TEXT_MAN_IP="Enter internal IP address of this VPN manually: "
TEXT_ERR_IP="Warning: Failed to automatically detect tunnel IP address."
TEXT_ASK_BYPASS="Enable Combined High-Performance IPSet Bypass module? (y/n) [n]: "
TEXT_ASK_DC="Do you need to route VPN clients into additional IPSec tunnels? (y/n) [n]: "
TEXT_NAME_DC="Enter exact IPSec Tunnel Name to DC from UniFi GUI [CP-DC.IPSEC]: "
TEXT_ASK_TG="Enable Telegram Notifications module? (y/n) [n]: "
TEXT_TG_TOKEN="Enter your Telegram Bot Token: "
TEXT_TG_CHAT="Enter your Telegram Chat ID: "
TEXT_ASK_WD="Enable background Watchdog module (connectivity check)? (y/n) [n]: "
TEXT_WD_INT="Enter connectivity check interval in minutes (1 to 59): "
TEXT_WD_WARN="Warning: Invalid interval. Setting default value: 5 minutes."
TEXT_DONE="Installation successfully completed! The module is ready."
MSG_ERR_PARAMS="Internet VPN parameters not found in kernel. Aborting."
MSG_ERR_TG="❌ Startup error. Interface \$EXIT_NODE_VPN_NAME is not active."
MSG_ERR_PING="Internet via interface is unavailable. Routing locked."
MSG_ERR_PING_TG="⚠️ Warning! Internet in tunnel \$EXIT_NODE_VPN_NAME is down. Activation blocked."
MSG_START="=== STARTING ROUTE SYNCHRONIZATION ==="
MSG_DC_ON="DC Module is enabled. DC Tunnel: \$DC_IPSEC_TUNNEL_NAME"
MSG_DC_OFF="DC Integration Module is DISABLED by user."
MSG_SUCCESS="All custom routing policies successfully added and activated."
MSG_SUCCESS_TG="✅ Custom routing successfully started. Internet exit via \$EXIT_NODE_VPN_NAME."
MSG_PING_TEST="Testing internet connectivity via tunnel"
TEXT_UP="Internet in tunnel \$EXIT_NODE_VPN_NAME restored. Activating routes."
TEXT_DOWN="Connection via tunnel \$EXIT_NODE_VPN_NAME lost! Deactivating rules."
TEXT_TG_DOWN="🚨 UDM SE Watchdog: Connection via tunnel \$EXIT_NODE_VPN_NAME lost! Rules disabled to restore default access. Interval: every \$WATCHDOG_INTERVAL_MINUTES min."
TEXT_CONFIRM="Are you sure you want to completely remove the module? (y/n): "
TEXT_CANCEL="Uninstall canceled."
TEXT_UNINST="Stopping and disabling systemd service..."
TEXT_CRON="Removing rules from cron and boot triggers..."
TEXT_KERNEL="Flushing active kernel routing tables and IPSet..."
TEXT_FILES="Removing project files..."
TEXT_SUCCESS="Uninstallation completed successfully! Routes restored to default."
MSG_BYPASS_ON="Bypass IPSet module is active. Loading firewall hash tables..."
MSG_BYPASS_OFF="Bypass IPSet module is disabled."
MSG_BYPASS_CLEAN="Bypass IPSet network rules flushed cleanly."
EOF
fi

# Подгружаем выбранную локализацию для инсталлятора
. "\(LANG_DIR/\){UI_LANG}.conf"

echo "====================================================="
echo "\$TEXT_BANNER"
echo "-----------------------------------------------------"

printf "%s" "\$TEXT_ASK_WG"
read -r INPUT_WG
EXIT_NODE_VPN_NAME="\${INPUT_WG:-WG-Zhmyak2}"

echo "\$TEXT_SCAN"
DETECTED_SYSTEM_INTERFACE=\$(ip link show | grep -o 'wgclt[0-9]*' | head -n 1)
if [ -n "\$DETECTED_SYSTEM_INTERFACE" ]; then
    DETECTED_IP=\$(ip -4 addr show dev "\$DETECTED_SYSTEM_INTERFACE" 2>/dev/null | grep -oE 'inet [0-9.]+' | awk '{print \$2}')
fi

if [ -n "\$DETECTED_IP" ]; then
    echo "\(TEXT_DET_IP\)DETECTED_IP"
    printf "%s" "\$TEXT_CONF_IP"
    read -r CONFIRM_IP
    if [ "\(CONFIRM_IP" = "n" ] \vert{}\vert{} [ "\)CONFIRM_IP" = "N" ]; then
        printf "%s" "\$TEXT_MAN_IP"
        read -r MANUAL_IP; EXIT_NODE_INTERNAL_IP="\$MANUAL_IP"
    else
        EXIT_NODE_INTERNAL_IP="\$DETECTED_IP"
    fi
else
    echo "\$TEXT_ERR_IP"
    printf "%s" "\$TEXT_MAN_IP"
    read -r MANUAL_IP; EXIT_NODE_INTERNAL_IP="\${MANUAL_IP:-10.151.0.3}"
fi

printf "%s" "\$TEXT_ASK_BYPASS"
read -r BYPASS_ENABLE
if [ "\(BYPASS_ENABLE" = "y" ] \vert{}\vert{} [ "\)BYPASS_ENABLE" = "Y" ]; then
    ENABLE_BYPASS_MODULE="true"
    if [ ! -f "\$BYPASS_LIST" ]; then
        cat << EOF > "\$BYPASS_LIST"
# Впишите сюда целевые IP-адреса или подсети для прямого выхода через WAN (в обход VPN)
# Каждая запись — строго со следующей строки. Пример:
# 95.213.255.1
# 185.32.0.0/16
EOF
    fi
else
    ENABLE_BYPASS_MODULE="false"
fi

printf "%s" "\$TEXT_ASK_DC"
read -r DC_ENABLE
if [ "\(DC_ENABLE" = "y" ] \vert{}\vert{} [ "\)DC_ENABLE" = "Y" ]; then
    ENABLE_DATACENTER_ROUTING="true"
    printf "%s" "\$TEXT_NAME_DC"
    read -r INPUT_IPSEC; DC_IPSEC_TUNNEL_NAME="\${INPUT_IPSEC:-CP-DC.IPSEC}"
else
    ENABLE_DATACENTER_ROUTING="false"; DC_IPSEC_TUNNEL_NAME=""
fi

printf "%s" "\$TEXT_ASK_TG"
read -r TG_ENABLE
if [ "\(TG_ENABLE" = "y" ] \vert{}\vert{} [ "\)TG_ENABLE" = "Y" ]; then
    ENABLE_TELEGRAM="true"
    printf "%s" "\$TEXT_TG_TOKEN"; read -r TELEGRAM_BOT_TOKEN
    printf "%s" "\$TEXT_TG_CHAT"; read -r TELEGRAM_CHAT_ID
else
    ENABLE_TELEGRAM="false"; TELEGRAM_BOT_TOKEN=""; TELEGRAM_CHAT_ID=""
fi

printf "%s" "\$TEXT_ASK_WD"
read -r WD_ENABLE

