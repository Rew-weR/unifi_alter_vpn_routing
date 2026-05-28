#!/bin/sh

# ===================================================================
# UNINSTALLER VERSION: v2.7.3-Stable (Safe & Atomic Purge)
# TOOL PATH: /data/vpn-router
# TARGET OS: UniFi OS 5.x (Debian-based)
# ===================================================================

CONFIG_FILE="/data/vpn-router/vpn-routing.conf"
SYSLOG_IDENTIFIER="CustomVPNRouting"

log_msg() {
    echo "[INFO] $1"
    logger -t "$SYSLOG_IDENTIFIER" "[UNINSTALL] $1"
}

if [ -f "$CONFIG_FILE" ]; then
    . "$CONFIG_FILE"
    LANG_FILE="/data/vpn-router/languages/${SYSTEM_LANGUAGE:-en}.conf"
    [ -f "$LANG_FILE" ] && . "$LANG_FILE"
fi

# Дефолтный текстовый парашют на случай отсутствия языковых пакетов
[ -z "$TEXT_CONFIRM" ] && TEXT_CONFIRM="Вы уверены, что хотите полностью удалить модуль? (y/n): "
[ -z "$TEXT_CANCEL" ] && TEXT_CANCEL="Отмена деинсталляции."
[ -z "$TEXT_UNINST" ] && TEXT_UNINST="Остановка и отключение системной службы systemd..."
[ -z "$TEXT_CRON" ] && TEXT_CRON="Удаление триггеров автозапуска и Watchdog из Cron..."
[ -z "$TEXT_KERNEL" ] && TEXT_KERNEL="Полная очистка активных таблиц ядра маршрутизации и IPSet..."
[ -z "$TEXT_FILES" ] && TEXT_FILES="Удаление файлов и каталогов проекта..."
[ -z "$TEXT_SUCCESS" ] && TEXT_SUCCESS="Деинсталляция успешно завершена! Система возвращена к заводским настройкам."

echo "====================================================="
printf "%s" "$TEXT_CONFIRM"
read -r CONFIRM
if [ "$CONFIRM" != "y" ] && [ "$CONFIRM" != "Y" ]; then
    echo "$TEXT_CANCEL"
    exit 0
fi

# ШАГ 1. Корректный демонтаж службы инициализации systemd
log_msg "$TEXT_UNINST"
systemctl stop custom-vpn-route.service 2>/dev/null
systemctl disable custom-vpn-route.service 2>/dev/null
rm -f /etc/systemd/system/custom-vpn-route.service
systemctl daemon-reload

# ШАГ 2. Безопасная атомарная очистка планировщика Cron без риска затереть системные задачи
log_msg "$TEXT_CRON"
crontab -l 2>/dev/null | grep -v "custom-vpn-route" | grep -v "vpn-watchdog.sh" | grep -v "vpn-bypass-loader.sh" > /tmp/cron_uninstall.txt
crontab /tmp/cron_uninstall.txt
rm -f /tmp/cron_uninstall.txt

# ШАГ 3. Точечный снос правил из ядра Linux строго по префиксам (Безопасно для чужих правил)
log_msg "$TEXT_KERNEL"
# Снос пула Bypass (900-999), Internet PBR (32600-32699) и DC Split (10000-10099)
for p in $(seq 900 999) $(seq 32600 32699) $(seq 10000 10099); do
    while ip rule del pref $p 2>/dev/null; do :; done
done

# ШАГ 4. Полная выгрузка хэш-таблицы IPSet из оперативной памяти ядра
if ipset list bypass_list >/dev/null 2>&1; then
    ipset flush bypass_list 2>/dev/null
    ipset destroy bypass_list 2>/dev/null
fi

# ШАГ 5. Удаление файловой структуры проекта
log_msg "$TEXT_FILES"
rm -rf /data/vpn-router
rm -f /data/install-vpn-router.sh

echo "-----------------------------------------------------"
log_msg "$TEXT_SUCCESS"
echo "====================================================="

